import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenTestSupport

@Suite("ChangeLog")
struct ChangeLogTests {
    struct Snapshot: Codable, Equatable {
        var title: String
    }

    @Test("local writes record ordered, local-origin changes")
    func localChanges() async throws {
        let clock = ManualTimeSource()
        let database = try Database.inMemory(timeSource: clock)
        let entity = EntityReference(kind: "task", id: UUID())
        try await database.write { db in
            try db.recordUpsert(entity, snapshot: Snapshot(title: "one"))
            try db.recordUpsert(entity, snapshot: Snapshot(title: "two"))
        }
        clock.advance(by: 5)
        try await database.write { db in try db.recordDeletion(entity) }

        let changes = try await database.read { db in try db.changes(after: 0) }
        #expect(changes.map(\.operation) == [.upsert, .upsert, .delete])
        #expect(changes.allSatisfy { $0.origin == .local })
        #expect(changes[0].timestamp < changes[1].timestamp)
        #expect(changes[1].timestamp < changes[2].timestamp)
        #expect(try changes[1].payload?.decode(as: Snapshot.self) == Snapshot(title: "two"))
        #expect(changes[2].payload == nil)
        #expect(changes.allSatisfy { $0.timestamp.replica == database.replicaID })
    }

    @Test("remote changes keep their timestamp and advance the local clock")
    func remoteChanges() async throws {
        let clock = ManualTimeSource()
        let database = try Database.inMemory(timeSource: clock)
        let entity = EntityReference(kind: "note", id: UUID())
        let future = HybridTimestamp(milliseconds: Int64(clock.now().timeIntervalSince1970 * 1000) + 60_000, counter: 3, replica: "remote")
        try await database.write(origin: .remote) { db in
            try db.recordChange(.upsert, entity: entity, payload: ["title": "from server"], timestamp: future)
        }
        try await database.write { db in try db.recordUpsert(entity, snapshot: Snapshot(title: "local edit")) }

        let changes = try await database.read { db in try db.history(of: entity) }
        #expect(changes.map(\.origin) == [.remote, .local])
        #expect(changes[0].timestamp == future)
        #expect(changes[1].timestamp > future)
        let localOnly = try await database.read { db in try db.changes(after: 0, origin: .local) }
        #expect(localOnly.count == 1)
        let latest = try await database.read { db in try db.latestTimestamp(of: entity) }
        #expect(latest == changes[1].timestamp)
    }

    @Test("rolled-back writes leave no change records")
    func rollbackDiscardsChanges() async throws {
        let database = try Database.inMemory()
        struct Abort: Error {}
        await #expect(throws: Abort.self) {
            try await database.write { db in
                try db.recordUpsert(EntityReference(kind: "task", id: UUID()), snapshot: Snapshot(title: "x"))
                throw Abort()
            }
        }
        let sequence = try await database.read { db in try db.latestChangeSequence() }
        #expect(sequence == 0)
    }
}
