import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenKnowledge
import LumenTestSupport

@Suite("CollectionService")
struct CollectionServiceTests {
    @Test("create appends to siblings, validates input and records the change")
    func create() async throws {
        let harness = try await KnowledgeHarness.make()
        let recorder = harness.recorder()
        let work = try await harness.collections.create(name: "  Work  ", symbolName: "briefcase")
        let home = try await harness.collections.create(name: "Home", symbolName: "  ")
        let projects = try await harness.collections.create(name: "Projects", parentID: work.id)

        #expect(work.name == "Work")
        #expect(work.symbolName == "briefcase")
        #expect(home.symbolName == nil)
        #expect([work.sortOrder, home.sortOrder, projects.sortOrder] as [Int] == [0, 1, 0])
        #expect(try await harness.collections.collection(projects.id)?.parentID == work.id)
        #expect(try await harness.changes(for: work.reference).map(\.operation) == [.upsert])

        let events = await recorder.waitForEvents(3)
        #expect(events.map(\.name) == Array(repeating: KnowledgeEvents.collectionCreated, count: 3))
        #expect(events.last?.attributes["parentID"] == .string(work.id.uuidString))

        await #expect(throws: ValidationError.self) { try await harness.collections.create(name: " \n ") }
        await #expect(throws: DatabaseError.self) { try await harness.collections.create(name: "Child", parentID: NoteCollection.ID()) }
    }

    @Test("rename and symbol changes save and publish updates")
    func renameAndSymbol() async throws {
        let harness = try await KnowledgeHarness.make()
        let collection = try await harness.collections.create(name: "Old")
        let recorder = harness.recorder()
        harness.clock.advance(by: 5)
        let renamed = try await harness.collections.rename(collection.id, to: "New")
        #expect(renamed.name == "New")
        #expect(renamed.updatedAt == harness.clock.now())
        #expect(try await harness.collections.setSymbol(collection.id, "star").symbolName == "star")
        #expect(try await harness.collections.setSymbol(collection.id, nil).symbolName == nil)
        #expect(try await harness.collections.rename(collection.id, to: "New") == renamed.with(symbolName: nil, updatedAt: harness.clock.now()))
        #expect(await recorder.waitForEvents(3).map(\.name) == Array(repeating: KnowledgeEvents.collectionUpdated, count: 3))
        await #expect(throws: ValidationError.self) { try await harness.collections.rename(collection.id, to: "") }
        #expect(try await harness.changes(for: collection.reference).count == 4)
    }

    @Test("moving into itself or a descendant is rejected; other moves append to the new siblings")
    func moveAndCycles() async throws {
        let harness = try await KnowledgeHarness.make()
        let root = try await harness.collections.create(name: "Root")
        let child = try await harness.collections.create(name: "Child", parentID: root.id)
        let grandchild = try await harness.collections.create(name: "Grandchild", parentID: child.id)
        let other = try await harness.collections.create(name: "Other")

        await #expect(throws: ValidationError.self) { try await harness.collections.move(root.id, to: root.id) }
        await #expect(throws: ValidationError.self) { try await harness.collections.move(root.id, to: grandchild.id) }
        await #expect(throws: ValidationError.self) { try await harness.collections.move(child.id, to: grandchild.id) }
        await #expect(throws: DatabaseError.self) { try await harness.collections.move(child.id, to: NoteCollection.ID()) }
        #expect(try await harness.collections.collection(root.id)?.parentID == nil)

        let moved = try await harness.collections.move(grandchild.id, to: nil)
        #expect(moved.parentID == nil)
        #expect(moved.sortOrder == 2)
        let underOther = try await harness.collections.move(root.id, to: other.id)
        #expect(underOther.parentID == other.id)
        #expect(try await harness.collections.tree().map(\.collection.name) == ["Other", "Grandchild"])
    }

    @Test("reorder puts the listed siblings first and keeps the rest in order")
    func reorder() async throws {
        let harness = try await KnowledgeHarness.make()
        let a = try await harness.collections.create(name: "A")
        let b = try await harness.collections.create(name: "B")
        let c = try await harness.collections.create(name: "C")
        let nested = try await harness.collections.create(name: "Nested", parentID: a.id)

        let recorder = harness.recorder()
        let ordered = try await harness.collections.reorder([c.id, a.id], in: nil)
        #expect(ordered.map(\.name) == ["C", "A", "B"])
        #expect(ordered.map(\.sortOrder) == [0, 1, 2])
        #expect(try await harness.collections.children(of: nil).map(\.id) == [c.id, a.id, b.id])
        #expect(await recorder.waitForEvents(3).count == 3)

        await #expect(throws: ValidationError.self) { try await harness.collections.reorder([nested.id], in: nil) }
        await #expect(throws: ValidationError.self) { try await harness.collections.reorder([a.id, a.id], in: nil) }
    }

    @Test("deleting a collection moves its notes, documents and children to its parent")
    func deleteMovesContents() async throws {
        let harness = try await KnowledgeHarness.make()
        let parent = try await harness.collections.create(name: "Parent")
        let existing = try await harness.collections.create(name: "Existing", parentID: parent.id)
        let doomed = try await harness.collections.create(name: "Doomed", parentID: parent.id)
        let child = try await harness.collections.create(name: "Child", parentID: doomed.id)
        let note = try await harness.notes.create(title: "Inside", collectionID: doomed.id)
        let document = try await harness.documents.import(data: Data("hello".utf8), fileName: "a.txt", contentType: DocumentContentType.plainText, collectionID: doomed.id)

        let recorder = harness.recorder()
        harness.clock.advance(by: 10)
        try await harness.collections.delete(doomed.id)

        #expect(try await harness.collections.collection(doomed.id) == nil)
        let movedChild = try await harness.collections.collection(child.id)
        #expect(movedChild?.parentID == parent.id)
        #expect(movedChild.map(\.sortOrder) ?? -1 > existing.sortOrder)
        #expect(try await harness.notes.note(note.id)?.collectionID == parent.id)
        #expect(try await harness.documents.document(document.id)?.collectionID == parent.id)

        #expect(try await harness.changes(for: doomed.reference).map(\.operation) == [.upsert, .delete])
        #expect(try await harness.changes(for: note.reference).count == 2)
        #expect(try await harness.changes(for: document.reference).count == 2)

        let events = await recorder.waitForEvents(4)
        #expect(Set(events.map(\.name)) == [
            KnowledgeEvents.collectionDeleted, KnowledgeEvents.collectionUpdated, KnowledgeEvents.noteUpdated, KnowledgeEvents.documentUpdated,
        ])
        let deletion = try #require(events.first { $0.name == KnowledgeEvents.collectionDeleted })
        #expect(deletion.attributes["movedNoteCount"] == 1)
        #expect(deletion.attributes["movedDocumentCount"] == 1)
        #expect(deletion.attributes["movedCollectionCount"] == 1)
    }

    @Test("deleting a top-level collection moves its contents to the root")
    func deleteTopLevel() async throws {
        let harness = try await KnowledgeHarness.make()
        let top = try await harness.collections.create(name: "Top")
        let child = try await harness.collections.create(name: "Child", parentID: top.id)
        let note = try await harness.notes.create(title: "Note", collectionID: top.id)
        try await harness.collections.delete(top.id)
        #expect(try await harness.collections.collection(child.id)?.parentID == nil)
        #expect(try await harness.notes.note(note.id)?.collectionID == nil)
        #expect(try await harness.collections.tree().map(\.collection.name) == ["Child"])
        await #expect(throws: DatabaseError.notFound(top.reference)) { try await harness.collections.delete(top.id) }
    }

    @Test("tree nests collections in display order")
    func tree() async throws {
        let harness = try await KnowledgeHarness.make()
        let work = try await harness.collections.create(name: "Work")
        let home = try await harness.collections.create(name: "Home")
        try await harness.collections.create(name: "Clients", parentID: work.id)
        try await harness.collections.create(name: "Admin", parentID: work.id)
        try await harness.collections.reorder([home.id], in: nil)

        let tree = try await harness.collections.tree()
        #expect(tree.map(\.collection.name) == ["Home", "Work"])
        #expect(tree[1].children.map(\.collection.name) == ["Clients", "Admin"])
        #expect(tree[1].children.allSatisfy { $0.depth == 1 })
        #expect(try await harness.collections.all().count == 4)
    }
}

extension NoteCollection {
    func with(symbolName: String?, updatedAt: Date) -> NoteCollection {
        var copy = self
        copy.symbolName = symbolName
        copy.updatedAt = updatedAt
        return copy
    }
}
