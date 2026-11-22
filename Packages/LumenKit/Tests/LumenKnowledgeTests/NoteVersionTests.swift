import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenKnowledge
import LumenTestSupport

@Suite("NoteService version history")
struct NoteVersionTests {
    let tenLines = (1...10).map { "line \($0)" }.joined(separator: "\n")

    @Test("versions follow the policy: first save, interval, large change")
    func policyDrivesSnapshots() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "Draft", body: tenLines)
        #expect(try await harness.notes.versions(of: note.id).count == 1)

        harness.clock.advance(by: 60)
        try await harness.notes.update(note.id, body: tenLines + " small")
        #expect(try await harness.notes.versions(of: note.id).count == 1)

        harness.clock.advance(by: 600)
        try await harness.notes.update(note.id, body: tenLines + " small edit")
        #expect(try await harness.notes.versions(of: note.id).count == 2)

        harness.clock.advance(by: 5)
        try await harness.notes.update(note.id, body: "completely\nrewritten")
        let versions = try await harness.notes.versions(of: note.id)
        #expect(versions.count == 3)
        #expect(versions.first?.body == "completely\nrewritten")
        #expect(versions.map(\.savedAt) == versions.map(\.savedAt).sorted(by: >))

        // Pinning does not touch title or body, so no version.
        harness.clock.advance(by: 3_600)
        try await harness.notes.pin(note.id)
        #expect(try await harness.notes.versions(of: note.id).count == 3)
    }

    @Test("old versions are pruned beyond the retention limit")
    func retention() async throws {
        let harness = try await KnowledgeHarness.make(versionPolicy: VersionPolicy(minimumInterval: 0, maximumVersionsPerNote: 3))
        let note = try await harness.notes.create(title: "T", body: "v0")
        for index in 1...5 {
            harness.clock.advance(by: 1)
            try await harness.notes.update(note.id, body: "v\(index)")
        }
        #expect(try await harness.notes.versions(of: note.id).map(\.body) == ["v5", "v4", "v3"])
    }

    @Test("restore snapshots the current state first, then brings the version back")
    func restore() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "Original", body: tenLines + "\n#alpha")
        let original = try #require(try await harness.notes.versions(of: note.id).first)
        harness.clock.advance(by: 30)
        // A small edit soon after: coalesced, no version yet.
        try await harness.notes.update(note.id, title: "Changed", body: tenLines + "\n#beta")
        #expect(try await harness.notes.versions(of: note.id).count == 1)

        let recorder = harness.recorder()
        harness.clock.advance(by: 30)
        let restored = try await harness.notes.restore(original.id)
        #expect(restored.title == "Original")
        #expect(restored.body == tenLines + "\n#alpha")
        #expect(restored.tags == ["alpha"])
        #expect(restored.updatedAt == harness.clock.now())

        let versions = try await harness.notes.versions(of: note.id)
        #expect(versions.map(\.title) == ["Changed", "Original"])
        #expect(versions.first?.body == tenLines + "\n#beta")

        let events = await recorder.waitForEvents(1)
        #expect(events.first?.name == KnowledgeEvents.noteUpdated)
        #expect(events.first?.attributes["restoredVersionID"] == .string(original.id.uuidString))
        #expect(try await harness.changes(for: note.reference).count == 3)
    }

    @Test("restoring a version equal to the current state changes nothing")
    func restoreNoOp() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "T", body: "same")
        let version = try #require(try await harness.notes.versions(of: note.id).first)
        harness.clock.advance(by: 30)
        #expect(try await harness.notes.restore(version.id) == note)
        #expect(try await harness.notes.versions(of: note.id).count == 1)
        let missing = NoteVersion.ID()
        await #expect(throws: KnowledgeError.versionNotFound(missing)) {
            try await harness.notes.restore(missing)
        }
    }

    @Test("diff between versions and against the current state")
    func diff() async throws {
        let harness = try await KnowledgeHarness.make(versionPolicy: VersionPolicy(minimumInterval: 0))
        let note = try await harness.notes.create(title: "Plan", body: "a\nb\nc")
        harness.clock.advance(by: 1)
        try await harness.notes.update(note.id, title: "Plan v2", body: "a\nB\nc")
        let versions = try await harness.notes.versions(of: note.id)
        let (newer, older) = (versions[0], versions[1])

        let between = try await harness.notes.diff(from: older.id, to: newer.id)
        #expect(between.titleChanged)
        #expect(between.oldTitle == "Plan" && between.newTitle == "Plan v2")
        #expect(between.body.summary == DiffSummary(added: 1, removed: 1, unchanged: 2))
        #expect(between.noteID == note.id)

        harness.clock.advance(by: 1)
        try await harness.notes.update(note.id, body: "a\nB\nc\nd")
        let toCurrent = try await harness.notes.diff(from: newer.id)
        #expect(toCurrent.toVersionID == nil)
        #expect(!toCurrent.titleChanged)
        #expect(toCurrent.body.changes.map(\.text) == ["d"])
    }

    @Test("diffing versions of different notes is rejected")
    func diffAcrossNotes() async throws {
        let harness = try await KnowledgeHarness.make()
        let first = try await harness.notes.create(title: "One", body: "1")
        let second = try await harness.notes.create(title: "Two", body: "2")
        let firstVersion = try #require(try await harness.notes.versions(of: first.id).first)
        let secondVersion = try #require(try await harness.notes.versions(of: second.id).first)
        await #expect(throws: ValidationError.self) {
            try await harness.notes.diff(from: firstVersion.id, to: secondVersion.id)
        }
    }

    @Test("versions are local history: only note changes reach the change log")
    func versionsAreNotSynchronized() async throws {
        let harness = try await KnowledgeHarness.make(versionPolicy: VersionPolicy(minimumInterval: 0))
        let note = try await harness.notes.create(title: "T", body: "1")
        harness.clock.advance(by: 1)
        try await harness.notes.update(note.id, body: "2")
        #expect(try await harness.notes.versions(of: note.id).count == 2)
        let kinds = Set(try await harness.changes().map(\.entity.kind))
        #expect(kinds == [.note])
    }
}
