import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenKnowledge
import LumenTestSupport

@Suite("Repositories")
struct RepositoryTests {
    @Test("schema creates the knowledge tables")
    func schema() async throws {
        let harness = try await KnowledgeHarness.make()
        #expect(KnowledgeSchema.schema.namespace == "knowledge")
        let tables = ["knowledge_notes", "knowledge_collections", "knowledge_documents", "knowledge_note_versions", "knowledge_links"]
        for table in tables {
            #expect(try await harness.database.read { db in try db.tableExists(table) }, "\(table)")
        }
        let report = try await harness.database.migrate([KnowledgeSchema.schema])
        #expect(report.applied.isEmpty)
    }

    @Test("sync writes (upsertRow / deleteRow) record no changes but keep links current")
    func syncWritesForNotes() async throws {
        let harness = try await KnowledgeHarness.make()
        let date = harness.clock.now()
        let target = Note(title: "Target", createdAt: date, updatedAt: date)
        let remote = Note(title: "Remote", body: "Links to [[Target]] #synced", tags: ["synced"], createdAt: date, updatedAt: date)
        try await harness.database.write(origin: .remote) { db in
            let repository = NoteRepository(db)
            try repository.upsertRow(target)
            try repository.upsertRow(remote)
        }
        #expect(try await harness.changes().isEmpty)
        #expect(try await harness.notes.note(remote.id) == remote)
        #expect(try await harness.notes.backlinks(to: target.reference).map(\.source) == [remote.reference])

        try await harness.database.write(origin: .remote) { db in try NoteRepository(db).deleteRow(remote.id) }
        #expect(try await harness.changes().isEmpty)
        #expect(try await harness.notes.backlinks(to: target.reference).isEmpty)
        #expect(try await harness.notes.note(remote.id) == nil)
    }

    @Test("sync writes for collections and documents record no changes; save and delete do")
    func syncWritesForCollectionsAndDocuments() async throws {
        let harness = try await KnowledgeHarness.make()
        let date = harness.clock.now()
        let collection = NoteCollection(name: "Synced", createdAt: date, updatedAt: date)
        let document = DocumentItem(
            title: "Doc", originalFileName: "d.pdf", contentType: DocumentContentType.pdf, byteCount: 1,
            sha256: String(repeating: "a", count: 64), storageKey: "a.pdf", collectionID: collection.id,
            createdAt: date, updatedAt: date
        )
        try await harness.database.write(origin: .remote) { db in
            try CollectionRepository(db).upsertRow(collection)
            try DocumentRepository(db).upsertRow(document)
        }
        #expect(try await harness.changes().isEmpty)
        #expect(try await harness.collections.collection(collection.id) == collection)
        #expect(try await harness.documents.document(document.id) == document)

        try await harness.database.write { db in
            try DocumentRepository(db).delete(document.id)
            try CollectionRepository(db).save(collection)
        }
        let changes = try await harness.changes()
        #expect(changes.map(\.operation) == [.delete, .upsert])
        #expect(changes.map(\.entity) == [document.reference, collection.reference])

        try await harness.database.write(origin: .remote) { db in try CollectionRepository(db).deleteRow(collection.id) }
        #expect(try await harness.changes().count == 2)
        #expect(try await harness.collections.all().isEmpty)
    }

    @Test("a failing transaction leaves neither row nor change record")
    func rollback() async throws {
        let harness = try await KnowledgeHarness.make()
        let date = harness.clock.now()
        let note = Note(title: "Doomed", createdAt: date, updatedAt: date)
        struct Abort: Error {}
        await #expect(throws: Abort.self) {
            try await harness.database.write { db in
                try NoteRepository(db).save(note)
                throw Abort()
            }
        }
        #expect(try await harness.notes.note(note.id) == nil)
        #expect(try await harness.changes().isEmpty)
    }

    @Test("tags are stored as JSON text")
    func tagsAsJSON() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "T", tags: ["one", "two"])
        let stored: String? = try await harness.database.read { db in
            try db.scalar("SELECT tags FROM knowledge_notes WHERE id = ?", [note.id])
        }
        #expect(stored == #"["one","two"]"#)
    }
}
