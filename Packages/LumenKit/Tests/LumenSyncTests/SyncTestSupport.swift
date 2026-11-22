import Foundation
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenSync
import LumenTestSupport

/// A server that stores pushed envelopes in order — the simplest possible transport, which is
/// exactly what the LWW-state design allows.
final class InMemorySyncServer: Sendable {
    private let log = Mutex<[SyncEnvelope]>([])
    let failures = Mutex<[SyncTransportError]>([])

    var envelopes: [SyncEnvelope] { log.withLock { $0 } }

    func push(_ envelopes: [SyncEnvelope]) throws {
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        log.withLock { $0.append(contentsOf: envelopes) }
    }

    func pull(after cursor: String?, limit: Int) throws -> PullResult {
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        let start = cursor.flatMap(Int.init) ?? 0
        let all = envelopes
        let end = min(all.count, start + limit)
        let slice = start < end ? Array(all[start..<end]) : []
        return PullResult(envelopes: slice, cursor: String(end), hasMore: end < all.count)
    }
}

struct ServerTransport: SyncTransport {
    let server: InMemorySyncServer
    /// Runs before each pull, e.g. to simulate the user editing while a sync is in flight.
    var beforePull: (@Sendable () async throws -> Void)?

    func push(_ envelopes: [SyncEnvelope]) async throws {
        try server.push(envelopes)
    }

    func pull(after cursor: String?, limit: Int) async throws -> PullResult {
        try await beforePull?()
        return try server.pull(after: cursor, limit: limit)
    }
}

/// A tiny synchronized entity used to exercise the engine.
struct Memo: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var pinned: Bool?
}

extension EntityKind {
    static let memo: EntityKind = "memo"
}

let memoSchema = DatabaseSchema(namespace: "memo", migrations: [
    .sql("0001", "CREATE TABLE memos (id TEXT PRIMARY KEY NOT NULL, json TEXT NOT NULL);"),
])

struct MemoHandler: SyncEntityHandler {
    let kind: EntityKind = .memo

    func snapshot(id: UUID, in db: DatabaseConnection) throws -> JSONValue? {
        guard let text: String = try db.scalar("SELECT json FROM memos WHERE id = ?", [id]) else { return nil }
        return try JSONValue(parsing: text)
    }

    func apply(_ snapshot: JSONValue, id: UUID, in db: DatabaseConnection) throws {
        try db.execute("INSERT OR REPLACE INTO memos (id, json) VALUES (?, ?)", [id, try snapshot.compactString()])
    }

    func remove(id: UUID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM memos WHERE id = ?", [id])
    }
}

/// One device: its own database, clock and sync engine, sharing a server with other replicas.
struct Replica {
    let database: Database
    let clock: ManualTimeSource
    let engine: SyncEngine
    let events: EventBus
    let logs: LogCapture

    static func make(
        server: InMemorySyncServer?,
        clock: ManualTimeSource = ManualTimeSource(),
        beforePull: (@Sendable () async throws -> Void)? = nil
    ) async throws -> Replica {
        let logs = LogCapture()
        let database = try Database(location: .inMemory, timeSource: clock)
        try await database.migrate([SyncEngine.schema, memoSchema])
        let events = EventBus()
        let engine = SyncEngine(
            database: database,
            transport: server.map { ServerTransport(server: $0, beforePull: beforePull) },
            handlers: [MemoHandler()],
            events: events,
            timeSource: clock,
            logger: logs.makeSystem().logger("sync"),
            retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: 1, jitter: 0),
            batchSize: 2,
            sleep: { _ in }
        )
        return Replica(database: database, clock: clock, engine: engine, events: events, logs: logs)
    }

    func save(_ memo: Memo) async throws {
        try await database.write { db in
            let snapshot = try JSONValue(encoding: memo)
            try MemoHandler().apply(snapshot, id: memo.id, in: db)
            try db.recordUpsert(EntityReference(kind: .memo, id: memo.id), snapshot: memo)
        }
    }

    func delete(_ id: UUID) async throws {
        try await database.write { db in
            try MemoHandler().remove(id: id, in: db)
            try db.recordDeletion(EntityReference(kind: .memo, id: id))
        }
    }

    func memo(_ id: UUID) async throws -> Memo? {
        try await database.read { db in try MemoHandler().snapshot(id: id, in: db) }.map { try $0.decode(as: Memo.self) }
    }
}

/// Lets a transport hook reach the replica it belongs to, and fire once when armed.
final class ReplicaHolder: Sendable {
    private let storage = Mutex<Replica?>(nil)
    private let armed = Mutex(false)

    var replica: Replica? { storage.withLock { $0 } }

    func set(_ replica: Replica) {
        storage.withLock { $0 = replica }
    }

    func armEdit() {
        armed.withLock { $0 = true }
    }

    /// True once after `armEdit()`.
    func shouldEdit() -> Bool {
        armed.withLock { value in
            defer { value = false }
            return value
        }
    }
}
