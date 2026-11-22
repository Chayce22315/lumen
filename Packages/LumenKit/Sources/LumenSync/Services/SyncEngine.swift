import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Local-first synchronization.
///
/// The app never waits for the network: every write lands in SQLite and the change log first.
/// A sync run pushes pending local changes as per-field LWW states, then pulls and merges remote
/// states. Transport failures are retried with backoff inside the run and, if they persist,
/// scheduled for a later attempt; going offline is a normal state, not an error.
public actor SyncEngine {
    public static let schema = SyncSchema.schema
    public static let runCompletedEvent: EventName = "sync.run.completed"
    public static let conflictDetectedEvent: EventName = "sync.conflict.detected"

    private let database: Database
    private var transport: (any SyncTransport)?
    private var handlers: [EntityKind: any SyncEntityHandler]
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger
    private let retryPolicy: RetryPolicy
    private let batchSize: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let store = SyncStore()

    private var state: SyncStatus.State
    private var isRunning = false
    private var consecutiveFailures = 0
    private var nextAttempt: Date?
    private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(
        database: Database,
        transport: (any SyncTransport)?,
        handlers: [any SyncEntityHandler],
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger,
        retryPolicy: RetryPolicy = .standard,
        batchSize: Int = 200,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.database = database
        self.transport = transport
        self.handlers = Dictionary(handlers.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
        self.retryPolicy = retryPolicy
        self.batchSize = max(1, batchSize)
        self.sleep = sleep
        self.state = transport == nil ? .notConfigured : .idle
    }

    // MARK: - Configuration

    public func setTransport(_ transport: (any SyncTransport)?) {
        self.transport = transport
        consecutiveFailures = 0
        nextAttempt = nil
        updateState(transport == nil ? .notConfigured : .idle)
    }

    public func register(_ handler: any SyncEntityHandler) {
        handlers[handler.kind] = handler
    }

    public var synchronizedKinds: Set<EntityKind> { Set(handlers.keys) }

    /// Forgets the cursor, push position and shadows (for example when switching accounts).
    /// The next run re-sends every local entity and re-reads everything remote.
    public func resetSynchronizationState() async throws {
        try await database.write { db in
            try db.execute("DELETE FROM sync_state")
            try db.execute("DELETE FROM sync_shadows")
        }
        await publishStatus()
    }

    // MARK: - Status

    public func status() async -> SyncStatus {
        let pending = (try? await pendingChangeCount()) ?? 0
        let conflicts = (try? await database.read { db in try SyncStore().conflicts(includeReviewed: false, in: db).count }) ?? 0
        let lastSuccess: Date? = try? await database.read { db in
            try SyncStore().value(SyncStore.lastSuccessKey, in: db).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
        return SyncStatus(state: state, lastSuccess: lastSuccess ?? nil, pendingChanges: pending, unreviewedConflicts: conflicts, nextAttempt: nextAttempt)
    }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(4))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func updateState(_ newState: SyncStatus.State) {
        state = newState
        Task { await publishStatus() }
    }

    private func publishStatus() async {
        let current = await status()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    /// Local changes of synchronized kinds not yet pushed.
    public func pendingChangeCount() async throws -> Int {
        let kinds = Array(handlers.keys)
        guard !kinds.isEmpty else { return 0 }
        let store = self.store
        return try await database.read { db in
            let pushed = try store.pushedSequence(in: db)
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
            var arguments: [any DatabaseValueConvertible] = [pushed]
            arguments.append(contentsOf: kinds.sorted() as [any DatabaseValueConvertible])
            return try db.scalar(
                "SELECT count(DISTINCT entity_kind || ':' || entity_id) FROM lumen_changes WHERE origin = 'local' AND sequence > ? AND entity_kind IN (\(placeholders))",
                arguments
            ) ?? 0
        }
    }

    // MARK: - Running

    /// Runs only when no backoff delay is pending.
    public func synchronizeIfDue() async -> SyncRun? {
        if let nextAttempt, timeSource.now() < nextAttempt { return nil }
        return await synchronize()
    }

    @discardableResult
    public func synchronize() async -> SyncRun {
        let startedAt = timeSource.now()
        guard let transport else {
            return SyncRun(startedAt: startedAt, finishedAt: startedAt, outcome: .skipped, pushed: 0, pulled: 0, conflicts: 0, errorMessage: nil)
        }
        guard !isRunning else {
            return SyncRun(startedAt: startedAt, finishedAt: startedAt, outcome: .skipped, pushed: 0, pulled: 0, conflicts: 0, errorMessage: "A sync is already running")
        }
        isRunning = true
        defer { isRunning = false }
        updateState(.syncing)

        var pushed = 0
        var pulled = 0
        var conflicts = 0
        let run: SyncRun
        do {
            pushed = try await pushPending(through: transport)
            (pulled, conflicts) = try await pullRemote(through: transport)
            let finished = timeSource.now()
            let store = self.store
            try await database.write { db in
                try store.setValue(String(finished.timeIntervalSince1970), for: SyncStore.lastSuccessKey, in: db)
            }
            consecutiveFailures = 0
            nextAttempt = nil
            run = SyncRun(startedAt: startedAt, finishedAt: finished, outcome: .succeeded, pushed: pushed, pulled: pulled, conflicts: conflicts, errorMessage: nil)
            updateState(.idle)
        } catch {
            consecutiveFailures += 1
            let finished = timeSource.now()
            let isOffline = (error as? SyncTransportError) == .offline
            let delay = retryPolicy.delay(beforeRetry: min(consecutiveFailures, 10), randomUnit: Double.random(in: 0...1))
            nextAttempt = finished.addingTimeInterval(max(delay, 5))
            run = SyncRun(
                startedAt: startedAt, finishedAt: finished, outcome: isOffline ? .offline : .failed,
                pushed: pushed, pulled: pulled, conflicts: conflicts, errorMessage: String(describing: error)
            )
            if isOffline {
                logger.notice("Sync deferred: offline")
                updateState(.offline)
            } else {
                logger.error("Sync failed", error: error)
                updateState(.failed(ErrorPresentation.from(error)))
            }
        }

        let finishedRun = run
        let store = self.store
        do {
            try await database.write { db in try store.insert(finishedRun, in: db) }
        } catch {
            logger.error("Sync history could not be saved", error: error)
        }
        events.publish(DomainEvent(
            name: Self.runCompletedEvent,
            attributes: ["outcome": .string(run.outcome.rawValue), "pushed": .number(Double(pushed)), "pulled": .number(Double(pulled)), "conflicts": .number(Double(conflicts))],
            actor: .sync,
            occurredAt: run.finishedAt
        ))
        return run
    }

    // MARK: - Push

    private func pushPending(through transport: any SyncTransport) async throws -> Int {
        var total = 0
        let kinds = Set(handlers.keys)
        let store = self.store
        let replica = database.replicaID
        let batchSize = self.batchSize
        while true {
            let batch: (envelopes: [SyncEnvelope], lastSequence: Int64)? = try await database.read { db in
                let pushedSequence = try store.pushedSequence(in: db)
                let changes = try db.changes(after: pushedSequence, origin: .local, limit: batchSize)
                guard let last = changes.last else { return nil }
                var seen = Set<EntityReference>()
                var envelopes: [SyncEnvelope] = []
                // Most recently touched entities are built once, with all their pending changes.
                for change in changes where kinds.contains(change.entity.kind) && seen.insert(change.entity).inserted {
                    let shadow = try store.shadow(of: change.entity, in: db)?.state ?? .empty
                    let (previous, pending) = try store.pendingChanges(for: change.entity, after: pushedSequence, in: db)
                    let state = EntityStateBuilder.localState(shadow: shadow, previous: previous, pending: pending)
                    envelopes.append(SyncEnvelope(entity: change.entity, state: state, origin: replica))
                }
                return (envelopes, last.sequence)
            }
            guard let batch else { return total }

            if !batch.envelopes.isEmpty {
                let envelopes = batch.envelopes
                try await withRetry(policy: retryPolicy, classify: Self.classify, sleep: sleep) {
                    try await transport.push(envelopes)
                }
            }
            try await database.write { db in
                for envelope in batch.envelopes {
                    let shadow = try store.shadow(of: envelope.entity, in: db) ?? .empty
                    try store.saveShadow(shadow.observing(envelope.state), of: envelope.entity, in: db)
                }
                try store.setValue(String(batch.lastSequence), for: SyncStore.pushedSequenceKey, in: db)
            }
            total += batch.envelopes.count
        }
    }

    // MARK: - Pull

    private func pullRemote(through transport: any SyncTransport) async throws -> (pulled: Int, conflicts: Int) {
        var pulled = 0
        var conflictCount = 0
        let store = self.store
        var cursor: String? = try await database.read { db in try store.value(SyncStore.cursorKey, in: db) }
        while true {
            let requestCursor = cursor
            let batchSize = self.batchSize
            let result = try await withRetry(policy: retryPolicy, classify: Self.classify, sleep: sleep) {
                try await transport.pull(after: requestCursor, limit: batchSize)
            }
            for envelope in result.envelopes where envelope.origin != database.replicaID {
                guard let handler = handlers[envelope.entity.kind] else {
                    logger.warning("Skipping remote change of unknown kind", metadata: ["kind": envelope.entity.kind.rawValue])
                    continue
                }
                if let conflict = try await apply(envelope, handler: handler) {
                    conflictCount += 1
                    events.publish(DomainEvent(name: Self.conflictDetectedEvent, entity: conflict.entity, attributes: ["fields": .number(Double(conflict.fields.count))], actor: .sync, occurredAt: conflict.detectedAt))
                }
                pulled += 1
            }
            let nextCursor = result.cursor
            try await database.write { db in try store.setValue(nextCursor, for: SyncStore.cursorKey, in: db) }
            cursor = nextCursor
            if !result.hasMore || result.envelopes.isEmpty { return (pulled, conflictCount) }
        }
    }

    /// Merges one remote state into the local entity. Returns a conflict when both sides changed
    /// the same field differently since they last agreed.
    private func apply(_ envelope: SyncEnvelope, handler: any SyncEntityHandler) async throws -> SyncConflict? {
        let store = self.store
        let now = timeSource.now()
        let replica = database.replicaID
        return try await database.write(origin: .remote) { db in
            let entity = envelope.entity
            let record = try store.shadow(of: entity, in: db) ?? .empty
            let shadow = record.state
            let pushedSequence = try store.pushedSequence(in: db)
            let (previous, pending) = try store.pendingChanges(for: entity, after: pushedSequence, in: db)
            let local = pending.isEmpty ? shadow : EntityStateBuilder.localState(shadow: shadow, previous: previous, pending: pending)
            let merged = local.merged(with: envelope.state)

            let currentSnapshot = try handler.snapshot(id: entity.id, in: db)
            if let snapshot = merged.snapshot {
                if snapshot != currentSnapshot {
                    try handler.apply(snapshot, id: entity.id, in: db)
                    try db.recordChange(.upsert, entity: entity, payload: snapshot, timestamp: envelope.state.latestTimestamp)
                }
            } else if merged.isDeleted, currentSnapshot != nil {
                try handler.remove(id: entity.id, in: db)
                try db.recordChange(.delete, entity: entity, payload: nil, timestamp: envelope.state.latestTimestamp)
            }
            try store.saveShadow(record.observing(envelope.state), of: entity, in: db)

            // Our unsynchronized edits racing remote ones…
            var fields = pending.isEmpty ? [] : EntityStateBuilder.conflicts(shadow: shadow, local: local, remote: envelope.state)
            // …and remote writes we had never seen that lost to a different value here.
            for (key, incoming) in envelope.state.fields.sorted(by: { $0.key < $1.key }) {
                let writer = incoming.timestamp.replica
                guard writer != replica,
                      incoming.timestamp > (record.observed[writer] ?? .zero),
                      let winner = merged.fields[key],
                      winner.timestamp > incoming.timestamp,
                      winner.value != incoming.value,
                      !fields.contains(where: { $0.field == key }) else { continue }
                fields.append(FieldConflict(field: key, localValue: winner.value, remoteValue: incoming.value, chosen: .local))
            }
            guard !fields.isEmpty else { return nil }
            let conflict = SyncConflict(entity: entity, fields: fields, detectedAt: now)
            try store.insert(conflict, in: db)
            return conflict
        }
    }

    // MARK: - Conflicts and history

    public func conflicts(includeReviewed: Bool = false) async throws -> [SyncConflict] {
        let store = self.store
        return try await database.read { db in try store.conflicts(includeReviewed: includeReviewed, in: db) }
    }

    public func markReviewed(_ id: SyncConflict.ID) async throws {
        let now = timeSource.now()
        try await database.write { db in
            try db.execute("UPDATE sync_conflicts SET reviewed_at = ? WHERE id = ?", [now, id])
        }
        await publishStatus()
    }

    /// Re-applies the values that lost a conflict as a new local edit, which then synchronizes.
    public func restoreLosingValues(of id: SyncConflict.ID) async throws {
        let store = self.store
        let now = timeSource.now()
        let handlers = self.handlers
        try await database.write { db in
            guard let conflict = try store.conflicts(includeReviewed: true, in: db).first(where: { $0.id == id }) else {
                throw DatabaseError.notFound(EntityReference(kind: "sync-conflict", id: id.rawValue))
            }
            guard let handler = handlers[conflict.entity.kind] else { return }
            var fields = try handler.snapshot(id: conflict.entity.id, in: db)?.objectValue ?? [:]
            for field in conflict.fields {
                let losing = field.chosen == .remote ? field.localValue : field.remoteValue
                if field.field == "*" {
                    if let whole = losing?.objectValue { fields = whole }
                } else {
                    fields[field.field] = losing
                }
            }
            let restored = JSONValue.object(fields)
            try handler.apply(restored, id: conflict.entity.id, in: db)
            try db.recordChange(.upsert, entity: conflict.entity, payload: restored, timestamp: nil)
            try db.execute("UPDATE sync_conflicts SET reviewed_at = ? WHERE id = ?", [now, id])
        }
    }

    public func history(limit: Int = 50) async throws -> [SyncRun] {
        let store = self.store
        return try await database.read { db in try store.runs(limit: limit, in: db) }
    }

    static func classify(_ error: any Error) -> RetryDecision {
        guard let error = error as? SyncTransportError else { return .retry }
        switch error {
        case .offline, .unauthorized, .rejected: return .fail
        case .unavailable(let retryAfter): return retryAfter.map(RetryDecision.retryAfter) ?? .retry
        }
    }
}

extension SyncTransportError: PresentableError {
    public var presentation: ErrorPresentation {
        switch self {
        case .offline:
            return ErrorPresentation(title: "Offline", message: "Changes are saved on this device and will sync when you're back online.", isRetryable: true)
        case .unauthorized:
            return ErrorPresentation(title: "Sign in again", message: "The sync service rejected Lumen's credentials.", recoverySuggestion: "Reconnect sync in Settings.")
        case .unavailable:
            return ErrorPresentation(title: "Sync unavailable", message: "The sync service is temporarily unavailable. Lumen will try again.", isRetryable: true)
        case .rejected(let reason):
            return ErrorPresentation(title: "Sync rejected", message: reason)
        }
    }
}
