import Foundation
import LumenFoundation

/// Synchronization over a cloud record database (CloudKit's private database in the app).
///
/// Each entity is one record holding its merged `EntityState`. Pushing reads the server record,
/// merges (the merge is a CRDT join, so this never loses a write), and saves with the server's
/// change tag; if another device saved in between, the save comes back as a conflict and is
/// merged again. Pulling reads the zone's change feed; the cursor is the archived change token.
/// Document files travel as asset records addressed by SHA-256.
public actor CloudSyncTransport: SyncTransport, BlobTransport {
    private let database: any CloudRecordDatabase
    private let logger: Logger
    private let maximumRecordsPerRequest: Int
    private let maximumRequestBytes: Int
    private let inlineStateLimit: Int
    /// Rounds of re-merging after save conflicts before giving up for this run.
    private let maximumConflictRounds = 5
    private var zoneVerified = false

    public init(
        database: any CloudRecordDatabase,
        logger: Logger,
        maximumRecordsPerRequest: Int = CloudLimits.maximumRecordsPerRequest,
        maximumRequestBytes: Int = CloudLimits.maximumRequestBytes,
        inlineStateLimit: Int = CloudLimits.inlineStateLimit
    ) {
        self.database = database
        self.logger = logger
        self.maximumRecordsPerRequest = max(1, maximumRecordsPerRequest)
        self.maximumRequestBytes = max(1, maximumRequestBytes)
        self.inlineStateLimit = max(1, inlineStateLimit)
    }

    // MARK: - Zone

    public func prepare(hasSynchronizedBefore: Bool) async throws {
        if zoneVerified { return }
        let exists = try await mapped { [database] in try await database.zoneExists() }
        if !exists {
            try await mapped { [database] in try await database.createZone() }
            zoneVerified = true
            if hasSynchronizedBefore {
                logger.notice("The sync zone was missing and has been recreated")
                throw SyncTransportError.remoteReset
            }
            return
        }
        zoneVerified = true
    }

    /// A zone that disappears mid-session was deleted with the user's iCloud data.
    private func zoneLost() -> SyncTransportError {
        zoneVerified = false
        return .remoteReset
    }

    // MARK: - Push

    public func push(_ envelopes: [SyncEnvelope]) async throws {
        // One state per entity: later envelopes for the same entity merge into earlier ones.
        var states: [EntityReference: SyncEnvelope] = [:]
        var order: [EntityReference] = []
        for envelope in envelopes {
            if let existing = states[envelope.entity] {
                states[envelope.entity] = SyncEnvelope(entity: envelope.entity, state: existing.state.merged(with: envelope.state), origin: envelope.origin)
            } else {
                states[envelope.entity] = envelope
                order.append(envelope.entity)
            }
        }
        let unique = order.compactMap { states[$0] }
        for chunk in CloudBatching.chunks(unique, maximumCount: maximumRecordsPerRequest) {
            try await pushChunk(chunk)
        }
    }

    private func pushChunk(_ envelopes: [SyncEnvelope]) async throws {
        let byID = Dictionary(envelopes.map { (CloudRecordCodec.recordID(for: $0.entity), $0) }, uniquingKeysWith: { first, _ in first })
        let existing = try await mapped { [database] in try await database.records(Array(byID.keys)) }
        var records = try byID.values.map { try record(for: $0, merging: existing[CloudRecordCodec.recordID(for: $0.entity)]) }
        records.sort { $0.id < $1.id }

        for round in 1...maximumConflictRounds {
            let outcomes = try await save(records)
            var retry: [CloudRecord] = []
            for record in records {
                switch outcomes[record.id] {
                case .saved?:
                    continue
                case .conflict(let server)?:
                    guard let envelope = byID[record.id] else { continue }
                    retry.append(try self.record(for: envelope, merging: server))
                case .failed(let error)?:
                    throw map(error)
                case nil:
                    throw SyncTransportError.unavailable(retryAfter: nil)
                }
            }
            if retry.isEmpty { return }
            logger.info("Merging concurrent cloud changes", metadata: ["records": String(retry.count), "round": String(round)])
            records = retry
        }
        throw SyncTransportError.unavailable(retryAfter: nil)
    }

    /// The record to save for `envelope`, merged with what the server has.
    private func record(for envelope: SyncEnvelope, merging server: CloudRecord?) throws -> CloudRecord {
        var state = envelope.state
        var origin = envelope.origin
        if let server, CloudRecordCodec.isEntityRecord(server) {
            let serverState = try CloudRecordCodec.state(of: server)
            let merged = serverState.merged(with: envelope.state)
            if merged != envelope.state {
                // The record now carries writes the pushing device hasn't seen: everyone,
                // including that device, must apply it when pulling.
                origin = CloudRecordCodec.mergedOrigin
            }
            state = merged
        }
        return try CloudRecordCodec.record(for: envelope.entity, state: state, origin: origin, existing: server, inlineLimit: inlineStateLimit)
    }

    /// Saves `records`, splitting requests that are too large.
    private func save(_ records: [CloudRecord]) async throws -> [CloudRecordID: CloudSaveOutcome] {
        var outcomes: [CloudRecordID: CloudSaveOutcome] = [:]
        for batch in CloudBatching.requests(records, maximumCount: maximumRecordsPerRequest, maximumBytes: maximumRequestBytes) {
            try await save(batch, into: &outcomes)
        }
        return outcomes
    }

    private func save(_ batch: [CloudRecord], into outcomes: inout [CloudRecordID: CloudSaveOutcome]) async throws {
        do {
            let result = try await database.save(batch)
            outcomes.merge(result) { _, new in new }
        } catch CloudDatabaseError.limitExceeded {
            guard batch.count > 1 else {
                throw SyncTransportError.rejected("A change is too large to sync.")
            }
            let middle = batch.count / 2
            try await save(Array(batch[..<middle]), into: &outcomes)
            try await save(Array(batch[middle...]), into: &outcomes)
        } catch let error as CloudDatabaseError {
            throw map(error)
        }
    }

    // MARK: - Pull

    public func pull(after cursor: String?, limit: Int) async throws -> PullResult {
        var token = try cursor.map(Self.token(from:))
        var envelopes: [SyncEnvelope] = []
        while true {
            let batch: CloudChangeBatch
            do {
                batch = try await database.changes(since: token, limit: max(1, limit))
            } catch CloudDatabaseError.changeTokenExpired {
                guard token != nil else { throw SyncTransportError.unavailable(retryAfter: nil) }
                // Read everything again; merging is idempotent, so re-applying known states is safe.
                logger.notice("Change token expired; reading all cloud changes again")
                token = nil
                continue
            } catch let error as CloudDatabaseError {
                throw map(error)
            }
            for record in batch.changed where CloudRecordCodec.isEntityRecord(record) {
                do {
                    envelopes.append(try CloudRecordCodec.envelope(from: record))
                } catch {
                    // A record written by a newer Lumen or damaged: skip it rather than block sync.
                    logger.warning("Skipping an unreadable cloud record", metadata: ["reason": String(describing: error)])
                }
            }
            token = batch.token
            // Pages holding only file records carry nothing for the engine; keep reading so an
            // empty page doesn't end the pull early.
            if !envelopes.isEmpty || !batch.moreComing {
                return PullResult(envelopes: envelopes, cursor: Self.cursor(from: batch.token), hasMore: batch.moreComing)
            }
        }
    }

    static func cursor(from token: Data) -> String {
        token.base64EncodedString()
    }

    static func token(from cursor: String) throws -> Data {
        guard let data = Data(base64Encoded: cursor) else {
            throw SyncTransportError.rejected("The saved sync position is unreadable.")
        }
        return data
    }

    // MARK: - Blobs

    public func containsBlob(sha256: String) async throws -> Bool {
        let id = CloudRecordCodec.blobRecordID(sha256: sha256)
        return try await mapped { [database] in try await database.records([id]) }[id] != nil
    }

    public func uploadBlob(_ data: Data, sha256: String) async throws {
        let record = CloudRecordCodec.blobRecord(data: data, sha256: sha256)
        let outcomes = try await mapped { [database] in try await database.save([record]) }
        switch outcomes[record.id] {
        case .saved?, .conflict?:
            // A conflict means another device uploaded the same content first.
            return
        case .failed(let error)?:
            throw map(error)
        case nil:
            throw SyncTransportError.unavailable(retryAfter: nil)
        }
    }

    public func downloadBlob(sha256: String) async throws -> Data? {
        let id = CloudRecordCodec.blobRecordID(sha256: sha256)
        guard let record = try await mapped({ [database] in try await database.records([id]) })[id] else { return nil }
        return try CloudRecordCodec.blobData(of: record)
    }

    // MARK: - Errors

    private func mapped<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as CloudDatabaseError {
            throw map(error)
        }
    }

    private func map(_ error: CloudDatabaseError) -> SyncTransportError {
        switch error {
        case .network: return .offline
        case .notAuthenticated: return .unauthorized
        case .quotaExceeded: return .rejected("Your iCloud storage is full.")
        case .unavailable(let retryAfter): return .unavailable(retryAfter: retryAfter)
        case .zoneNotFound: return zoneLost()
        case .changeTokenExpired, .limitExceeded: return .unavailable(retryAfter: nil)
        case .other(let reason): return .rejected(reason)
        }
    }
}

/// Splits work into requests that respect CloudKit's limits. Pure.
public enum CloudBatching {
    public static func chunks<T>(_ items: [T], maximumCount: Int) -> [[T]] {
        let size = max(1, maximumCount)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Consecutive groups of at most `maximumCount` records and about `maximumBytes` inline bytes.
    /// A single record larger than the byte budget gets a request of its own.
    public static func requests(_ records: [CloudRecord], maximumCount: Int, maximumBytes: Int) -> [[CloudRecord]] {
        var requests: [[CloudRecord]] = []
        var current: [CloudRecord] = []
        var bytes = 0
        for record in records {
            let size = record.inlineByteCount
            if !current.isEmpty, current.count >= maximumCount || bytes + size > maximumBytes {
                requests.append(current)
                current = []
                bytes = 0
            }
            current.append(record)
            bytes += size
        }
        if !current.isEmpty { requests.append(current) }
        return requests
    }
}
