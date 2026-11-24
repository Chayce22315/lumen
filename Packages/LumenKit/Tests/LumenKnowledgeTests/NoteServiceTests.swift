import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenKnowledge
import LumenTestSupport

@Suite("NoteService")
struct NoteServiceTests {
    @Test("create stores the note, merges hashtags into tags, records a change and publishes after commit")
    func create() async throws {
        let harness = try await KnowledgeHarness.make()
        let recorder = harness.recorder()
        let note = try await harness.notes.create(title: "  Weekly   plan ", body: "Focus on #Deep-Work and #health", tags: ["Work", "#work"])

        #expect(note.title == "Weekly plan")
        #expect(note.tags == ["work", "deep-work", "health"])
        #expect(note.createdAt == harness.clock.now())
        #expect(try await harness.notes.note(note.id) == note)
        #expect(try await harness.notes.versions(of: note.id).count == 1)

        let changes = try await harness.changes(for: note.reference)
        #expect(changes.map(\.operation) == [.upsert])
        #expect(try changes.first?.payload?.decode(as: Note.self) == note)

        let events = await recorder.waitForEvents(1)
        #expect(events.map(\.name) == [KnowledgeEvents.noteCreated])
        #expect(events.first?.entity == note.reference)
        #expect(events.first?.actor == .user)
        #expect(events.first?.attributes == ["tagCount": 3])
    }

    @Test("creating into a missing collection fails without writing or publishing")
    func createInMissingCollection() async throws {
        let harness = try await KnowledgeHarness.make()
        let recorder = harness.recorder()
        let missing = NoteCollection.ID()
        await #expect(throws: DatabaseError.notFound(EntityReference(kind: .collection, id: missing))) {
            try await harness.notes.create(title: "x", collectionID: missing)
        }
        #expect(try await harness.notes.allNotes().isEmpty)
        #expect(try await harness.changes().isEmpty)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.events.isEmpty)
    }

    @Test("update re-derives tags: removed hashtags drop their tag, explicit tags stay")
    func updateRetags() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "Ideas", body: "#alpha #beta", tags: ["explicit"])
        harness.clock.advance(by: 30)
        let updated = try await harness.notes.update(note.id, body: "#beta #gamma")
        #expect(updated.tags == ["explicit", "beta", "gamma"])
        #expect(updated.updatedAt == harness.clock.now())
        #expect(updated.createdAt == note.createdAt)

        let renamed = try await harness.notes.update(note.id, title: "Better ideas")
        #expect(renamed.title == "Better ideas")
        #expect(renamed.body == "#beta #gamma")
        #expect(try await harness.changes(for: note.reference).count == 3)
    }

    @Test("an update that changes nothing writes and publishes nothing")
    func noOpUpdate() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "Same", body: "body")
        let recorder = harness.recorder()
        harness.clock.advance(by: 60)
        let result = try await harness.notes.update(note.id, title: "Same", body: "body")
        let pinnedTwice = try await harness.notes.unpin(note.id)
        #expect(result == note)
        #expect(pinnedTwice.updatedAt == note.updatedAt)
        #expect(try await harness.changes(for: note.reference).count == 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.events.isEmpty)
    }

    @Test("setTags replaces explicit tags but keeps hashtags from the body")
    func setTags() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "T", body: "about #topic", tags: ["old"])
        let tagged = try await harness.notes.setTags(note.id, ["New", "  ", "new"])
        #expect(tagged.tags == ["new", "topic"])
    }

    @Test("move validates the collection and supports moving back to the root")
    func move() async throws {
        let harness = try await KnowledgeHarness.make()
        let work = try await harness.collections.create(name: "Work")
        let note = try await harness.notes.create(title: "T")
        let moved = try await harness.notes.move(note.id, to: work.id)
        #expect(moved.collectionID == work.id)
        await #expect(throws: DatabaseError.self) {
            try await harness.notes.move(note.id, to: NoteCollection.ID())
        }
        #expect(try await harness.notes.note(note.id)?.collectionID == work.id)
        #expect(try await harness.notes.move(note.id, to: nil).collectionID == nil)
    }

    @Test("pin, archive and unarchive publish the right events")
    func pinAndArchive() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "T")
        let recorder = harness.recorder()
        #expect(try await harness.notes.pin(note.id).isPinned)
        #expect(try await harness.notes.archive(note.id).isArchived)
        #expect(try await harness.notes.notes().isEmpty)
        #expect(try await harness.notes.unarchive(note.id).isArchived == false)
        #expect(try await harness.notes.unpin(note.id).isPinned == false)
        let names = await recorder.waitForEvents(4).map(\.name)
        #expect(names == [KnowledgeEvents.noteUpdated, KnowledgeEvents.noteArchived, KnowledgeEvents.noteRestored, KnowledgeEvents.noteUpdated])
    }

    @Test("delete removes the note with its links and versions and records the deletion")
    func delete() async throws {
        let harness = try await KnowledgeHarness.make()
        let target = try await harness.notes.create(title: "Target")
        let note = try await harness.notes.create(title: "Source", body: "See [[Target]]")
        let recorder = harness.recorder()
        try await harness.notes.delete(note.id)

        #expect(try await harness.notes.note(note.id) == nil)
        #expect(try await harness.notes.versions(of: note.id).isEmpty)
        #expect(try await harness.notes.outgoingLinks(from: note.id).isEmpty)
        #expect(try await harness.notes.backlinks(to: target.reference).isEmpty)
        #expect(try await harness.changes(for: note.reference).map(\.operation) == [.upsert, .delete])
        let events = await recorder.waitForEvents(1)
        #expect(events.map(\.name) == [KnowledgeEvents.noteDeleted])
        await #expect(throws: DatabaseError.notFound(note.reference)) {
            try await harness.notes.delete(note.id)
        }
    }

    @Test("queries filter by collection, tag, pinned and archived state, sort and limit")
    func queries() async throws {
        let harness = try await KnowledgeHarness.make()
        let work = try await harness.collections.create(name: "Work")
        let banana = try await harness.notes.create(title: "banana", body: "#fruit", collectionID: work.id)
        harness.clock.advance(by: 10)
        let apple = try await harness.notes.create(title: "Apple", body: "#fruit #red")
        harness.clock.advance(by: 10)
        let cherry = try await harness.notes.create(title: "cherry", tags: ["red"])
        harness.clock.advance(by: 10)
        try await harness.notes.pin(banana.id)
        harness.clock.advance(by: 10)
        try await harness.notes.archive(cherry.id)

        #expect(try await harness.notes.notes().map(\.id) == [banana.id, apple.id])
        #expect(try await harness.notes.notes(query: NoteQuery(includeArchived: true, sort: .title)).map(\.title) == ["Apple", "banana", "cherry"])
        #expect(try await harness.notes.notes(query: NoteQuery(includeArchived: true, sort: .created)).map(\.id) == [cherry.id, apple.id, banana.id])
        #expect(try await harness.notes.notes(query: NoteQuery(collectionID: work.id)).map(\.id) == [banana.id])
        #expect(try await harness.notes.notes(query: NoteQuery(tag: "#Fruit")).map(\.id) == [banana.id, apple.id])
        #expect(try await harness.notes.notes(query: NoteQuery(tag: "red")).map(\.id) == [apple.id])
        #expect(try await harness.notes.notes(query: NoteQuery(tag: "red", includeArchived: true)).count == 2)
        #expect(try await harness.notes.notes(query: NoteQuery(tag: "  ")).isEmpty)
        #expect(try await harness.notes.notes(query: NoteQuery(pinnedOnly: true)).map(\.id) == [banana.id])
        #expect(try await harness.notes.notes(query: NoteQuery(includeArchived: true, limit: 1)).map(\.id) == [cherry.id])
    }

    @Test("recent, updatedSince and allNotes serve lists and reindexing")
    func listing() async throws {
        let harness = try await KnowledgeHarness.make()
        let first = try await harness.notes.create(title: "first")
        let checkpoint = harness.clock.now()
        harness.clock.advance(by: 5)
        let second = try await harness.notes.create(title: "second")
        harness.clock.advance(by: 5)
        try await harness.notes.archive(first.id)

        #expect(try await harness.notes.recent(limit: 5).map(\.id) == [second.id])
        #expect(try await harness.notes.notes(updatedSince: checkpoint).map(\.id) == [second.id, first.id])
        #expect(try await harness.notes.allNotes().map(\.id) == [first.id, second.id])
    }

    @Test("events carry the caller's actor, correlation and causation depth")
    func actionContext() async throws {
        let harness = try await KnowledgeHarness.make()
        let recorder = harness.recorder()
        let correlation = UUID()
        let context = ActionContext(actor: .automation, correlationID: correlation, causationDepth: 2)
        let note = try await harness.notes.create(title: "Auto", context: context)
        try await harness.notes.update(note.id, body: "changed", context: .system)
        let events = await recorder.waitForEvents(2)
        #expect(events.map(\.actor) == [.automation, .system])
        #expect(events.first?.correlationID == correlation)
        #expect(events.first?.causationDepth == 2)
        #expect(events.first?.occurredAt == harness.clock.now())
    }

    @Test("an event's subscriber can already read the committed note")
    func eventsAfterCommit() async throws {
        let harness = try await KnowledgeHarness.make()
        let stream = harness.environment.events.events(matching: EventFilter(names: [KnowledgeEvents.noteCreated]))
        let service = harness.notes
        let observer = Task { () -> Note? in
            for await event in stream {
                guard let entity = event.entity else { return nil }
                return try? await service.note(entity.identifier(as: Note.self))
            }
            return nil
        }
        let note = try await harness.notes.create(title: "Visible", body: "body")
        let seen = await observer.value
        #expect(seen == note)
    }
}
