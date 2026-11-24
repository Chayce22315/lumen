import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenSync
import LumenTestSupport

@Suite("SyncEngine")
struct SyncEngineTests {
    @Test("changes made on one device appear on another")
    func propagation() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let memo = Memo(id: UUID(), title: "Groceries", body: "Milk", pinned: true)
        try await a.save(memo)
        #expect(try await a.engine.pendingChangeCount() == 1)
        let pushed = await a.engine.synchronize()
        #expect(pushed.outcome == .succeeded)
        #expect(pushed.pushed == 1)
        #expect(try await a.engine.pendingChangeCount() == 0)

        let pulled = await b.engine.synchronize()
        #expect(pulled.pulled == 1)
        #expect(try await b.memo(memo.id) == memo)
        // B's apply is recorded as a remote change, so B has nothing to push back.
        #expect(try await b.engine.pendingChangeCount() == 0)
        // A skips its own envelope on the next pull.
        #expect(await a.engine.synchronize().pulled == 0)
    }

    @Test("concurrent edits to different fields both survive on every device")
    func differentFields() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let id = UUID()
        try await a.save(Memo(id: id, title: "Plan", body: "Draft", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()

        a.clock.advance(by: 10)
        try await a.save(Memo(id: id, title: "Plan v2", body: "Draft", pinned: nil))
        b.clock.advance(by: 20)
        try await b.save(Memo(id: id, title: "Plan", body: "Final body", pinned: nil))

        await a.engine.synchronize()
        await b.engine.synchronize()   // B pushes its body edit, then pulls A's title edit
        await a.engine.synchronize()   // A pulls B's body edit

        let expected = Memo(id: id, title: "Plan v2", body: "Final body", pinned: nil)
        #expect(try await a.memo(id) == expected)
        #expect(try await b.memo(id) == expected)
        #expect(try await a.engine.conflicts().isEmpty)
        #expect(try await b.engine.conflicts().isEmpty)
    }

    @Test("the later edit of the same field wins everywhere; the replica that overwrote records the conflict")
    func sameField() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let id = UUID()
        try await a.save(Memo(id: id, title: "Original", body: "", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()

        a.clock.advance(by: 30)
        try await a.save(Memo(id: id, title: "From A (later)", body: "", pinned: nil))
        b.clock.advance(by: 10)
        try await b.save(Memo(id: id, title: "From B (earlier)", body: "", pinned: nil))

        await a.engine.synchronize()
        await b.engine.synchronize()
        let run = await a.engine.synchronize()
        #expect(run.conflicts == 1)

        #expect(try await a.memo(id)?.title == "From A (later)")
        #expect(try await b.memo(id)?.title == "From A (later)")
        let conflicts = try await a.engine.conflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.fields == [FieldConflict(field: "title", localValue: "From A (later)", remoteValue: "From B (earlier)", chosen: .local)])
        #expect(try await b.engine.conflicts().isEmpty)
        // Pulling again does not re-report the conflict.
        _ = await a.engine.synchronize()
        #expect(try await a.engine.conflicts().count == 1)
    }

    @Test("an edit made while a sync is in flight is merged, not overwritten, and reported")
    func inFlightEdit() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let id = UUID()
        try await a.save(Memo(id: id, title: "Original", body: "", pinned: nil))
        await a.engine.synchronize()

        // B: a device whose user edits the title while B's pull is on the network.
        let clockB = ManualTimeSource()
        let holder = ReplicaHolder()
        let b = try await Replica.make(server: server, clock: clockB, beforePull: {
            guard let replica = holder.replica, holder.shouldEdit() else { return }
            clockB.advance(by: 100)
            try await replica.save(Memo(id: id, title: "B typed during sync", body: "", pinned: nil))
        })
        holder.set(b)
        await b.engine.synchronize()          // first pull brings "Original"; edit happens before it

        a.clock.advance(by: 20)
        try await a.save(Memo(id: id, title: "A edit", body: "Body from A", pinned: nil))
        await a.engine.synchronize()

        holder.armEdit()
        let run = await b.engine.synchronize() // B edits during this pull, then merges A's edit
        #expect(run.conflicts == 1)
        let merged = try #require(await b.memo(id))
        #expect(merged.title == "B typed during sync")  // newer local edit wins the field
        #expect(merged.body == "Body from A")           // A's other field still arrives
        let conflict = try #require(await b.engine.conflicts().first)
        #expect(conflict.fields.first?.chosen == .local)

        await b.engine.synchronize()
        await a.engine.synchronize()
        #expect(try await a.memo(id) == merged)
    }

    @Test("a deletion wins over older edits; a newer edit resurrects the entity")
    func deletions() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let first = UUID()
        let second = UUID()
        try await a.save(Memo(id: first, title: "Delete me", body: "", pinned: nil))
        try await a.save(Memo(id: second, title: "Keep me", body: "", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()

        // first: B edits early, A deletes later → deleted everywhere.
        b.clock.advance(by: 5)
        try await b.save(Memo(id: first, title: "Edited early", body: "", pinned: nil))
        a.clock.advance(by: 10)
        try await a.delete(first)
        // second: A deletes early, B edits later → resurrected everywhere.
        try await a.delete(second)
        b.clock.advance(by: 30)
        try await b.save(Memo(id: second, title: "Edited late", body: "", pinned: nil))

        await a.engine.synchronize()
        await b.engine.synchronize()
        await a.engine.synchronize()

        #expect(try await a.memo(first) == nil)
        #expect(try await b.memo(first) == nil)
        #expect(try await a.memo(second)?.title == "Edited late")
        #expect(try await b.memo(second)?.title == "Edited late")
    }

    @Test("cleared optional fields synchronize")
    func clearedField() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let id = UUID()
        try await a.save(Memo(id: id, title: "Pinned", body: "", pinned: true))
        await a.engine.synchronize()
        await b.engine.synchronize()
        a.clock.advance(by: 5)
        try await a.save(Memo(id: id, title: "Pinned", body: "", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()
        #expect(try await b.memo(id)?.pinned == nil)
    }

    @Test("batches larger than the batch size are fully pushed and pulled")
    func batching() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let ids = (0..<7).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            try await a.save(Memo(id: id, title: "Memo \(index)", body: "", pinned: nil))
        }
        #expect(await a.engine.synchronize().pushed == 7)
        #expect(await b.engine.synchronize().pulled == 7)
        for id in ids {
            #expect(try await b.memo(id) != nil)
        }
    }

    @Test("transient failures are retried within a run")
    func retries() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        try await a.save(Memo(id: UUID(), title: "x", body: "", pinned: nil))
        server.failures.withLock { $0 = [.unavailable(retryAfter: nil), .unavailable(retryAfter: 2)] }
        let run = await a.engine.synchronize()
        #expect(run.outcome == .succeeded)
        #expect(server.envelopes.count == 1)
    }

    @Test("offline defers without an error and backs off")
    func offline() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        try await a.save(Memo(id: UUID(), title: "x", body: "", pinned: nil))
        server.failures.withLock { $0 = [.offline] }
        let run = await a.engine.synchronize()
        #expect(run.outcome == .offline)
        let status = await a.engine.status()
        #expect(status.state == .offline)
        #expect(status.pendingChanges == 1)
        #expect(status.nextAttempt != nil)
        #expect(await a.engine.synchronizeIfDue() == nil)
        a.clock.advance(by: 3_600)
        #expect(await a.engine.synchronizeIfDue()?.outcome == .succeeded)
        #expect(try await a.engine.history().map(\.outcome) == [.succeeded, .offline])
        #expect(a.logs.entries(atLeast: .error).isEmpty)
    }

    @Test("without a transport nothing leaves the device")
    func notConfigured() async throws {
        let a = try await Replica.make(server: nil)
        try await a.save(Memo(id: UUID(), title: "Local only", body: "", pinned: nil))
        #expect(await a.engine.synchronize().outcome == .skipped)
        #expect(await a.engine.status().state == .notConfigured)
        #expect(await a.engine.status().pendingChanges == 1)
    }

    @Test("restoring the losing values creates a new local edit that synchronizes")
    func restore() async throws {
        let server = InMemorySyncServer()
        let a = try await Replica.make(server: server)
        let b = try await Replica.make(server: server)
        let id = UUID()
        try await a.save(Memo(id: id, title: "Base", body: "", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()
        a.clock.advance(by: 50)
        try await a.save(Memo(id: id, title: "A (newer)", body: "", pinned: nil))
        b.clock.advance(by: 10)
        try await b.save(Memo(id: id, title: "B (older)", body: "", pinned: nil))
        await a.engine.synchronize()
        await b.engine.synchronize()
        await a.engine.synchronize()

        let conflict = try #require(await a.engine.conflicts().first)
        try await a.engine.restoreLosingValues(of: conflict.id)
        #expect(try await a.memo(id)?.title == "B (older)")
        #expect(try await a.engine.conflicts().isEmpty)
        #expect(try await a.engine.conflicts(includeReviewed: true).count == 1)
        await a.engine.synchronize()
        await b.engine.synchronize()
        #expect(try await b.memo(id)?.title == "B (older)")
    }

    @Test("remote changes of unknown kinds are skipped with a warning")
    func unknownKinds() async throws {
        let server = InMemorySyncServer()
        try server.push([SyncEnvelope(entity: EntityReference(kind: "future-kind", id: UUID()), state: EntityState(fields: ["x": FieldState(value: 1, timestamp: HybridTimestamp(milliseconds: 1, counter: 0, replica: "z"))]), origin: "z")])
        let a = try await Replica.make(server: server)
        let run = await a.engine.synchronize()
        #expect(run.outcome == .succeeded)
        #expect(run.pulled == 0)
        #expect(a.logs.entries(atLeast: .warning).contains { $0.metadata["kind"] == "future-kind" })
    }
}
