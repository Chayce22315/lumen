import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenKnowledge
import LumenTestSupport

@Suite("DocumentService")
struct DocumentServiceTests {
    let markdown = Data("# Meeting notes\n\nDiscussed the *roadmap*.".utf8)

    @Test("importing a text file hashes, stores, extracts text, records and publishes")
    func importText() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        let recorder = harness.recorder()
        let document = try await harness.documents.import(
            data: markdown, fileName: "Meeting Notes.MD", contentType: DocumentContentType.markdown, tags: ["Work", "work"]
        )
        let digest = SHA256.hexDigest(of: markdown)
        #expect(document.sha256 == digest)
        #expect(document.storageKey == "\(digest).md")
        #expect(document.title == "Meeting Notes")
        #expect(document.originalFileName == "Meeting Notes.MD")
        #expect(document.byteCount == Int64(markdown.count))
        #expect(document.extractedText == "# Meeting notes\n\nDiscussed the *roadmap*.")
        #expect(document.tags == ["work"])
        #expect(storage.base.keys == [document.storageKey])
        #expect(try await harness.documents.data(for: document.id) == markdown)
        #expect(try await harness.changes(for: document.reference).map(\.operation) == [.upsert])
        #expect(try await harness.changes(for: document.reference).first?.payload?.decode(as: DocumentItem.self) == document)

        let event = try #require(await recorder.waitForEvents(1).first)
        #expect(event.name == KnowledgeEvents.documentImported)
        #expect(event.attributes["contentType"] == .string(DocumentContentType.markdown))
        #expect(event.attributes["byteCount"] == .number(Double(markdown.count)))
        #expect(event.attributes["tagCount"] == 1)
    }

    @Test("binary formats get no extracted text and keep their extension")
    func importBinary() async throws {
        let harness = try await KnowledgeHarness.make()
        let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x00, 0xFF])
        let document = try await harness.documents.import(data: pdf, fileName: "scan.pdf", contentType: DocumentContentType.pdf, title: "  Tax   scan ")
        #expect(document.extractedText == nil)
        #expect(document.title == "Tax scan")
        #expect(document.storageKey.hasSuffix(".pdf"))
        #expect(try await harness.documents.fileURL(for: document.id) == nil)
    }

    @Test("long text is capped at 200 000 characters")
    func extractionCap() async throws {
        let harness = try await KnowledgeHarness.make()
        let big = Data(String(repeating: "x", count: 200_123).utf8)
        let document = try await harness.documents.import(data: big, fileName: "big.txt", contentType: DocumentContentType.plainText)
        #expect(document.extractedText?.count == DocumentService.maximumExtractedCharacters)
        #expect(document.byteCount == 200_123)
    }

    @Test("identical bytes return the existing document without writing again")
    func deduplication() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        let first = try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown)
        let recorder = harness.recorder()
        harness.clock.advance(by: 60)
        let again = try await harness.documents.import(data: markdown, fileName: "copy.md", contentType: DocumentContentType.markdown, title: "Copy")
        let renamedExtension = try await harness.documents.import(data: markdown, fileName: "notes.txt", contentType: DocumentContentType.plainText)

        #expect(again == first)
        #expect(renamedExtension == first)
        #expect(storage.writeCount == 1)
        #expect(storage.base.keys == [first.storageKey])
        #expect(try await harness.documents.allDocuments().count == 1)
        #expect(try await harness.changes().count == 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.events.isEmpty)
    }

    @Test("re-importing bytes whose file went missing restores the file")
    func restoresMissingFile() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        let document = try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown)
        try await storage.base.remove(key: document.storageKey)
        await #expect(throws: KnowledgeError.documentFileMissing(storageKey: document.storageKey)) {
            try await harness.documents.data(for: document.id)
        }
        #expect(try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown) == document)
        #expect(try await harness.documents.data(for: document.id) == markdown)
        #expect(storage.writeCount == 2)
    }

    @Test("delete removes the file when no other document references it")
    func deleteRemovesFile() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        let document = try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown)
        let recorder = harness.recorder()
        try await harness.documents.delete(document.id)
        #expect(storage.base.keys.isEmpty)
        #expect(try await harness.documents.document(document.id) == nil)
        #expect(try await harness.changes(for: document.reference).map(\.operation) == [.upsert, .delete])
        #expect(await recorder.waitForEvents(1).map(\.name) == [KnowledgeEvents.documentDeleted])
        await #expect(throws: DatabaseError.notFound(document.reference)) { try await harness.documents.delete(document.id) }
    }

    @Test("delete keeps a file that another document still references")
    func deleteKeepsSharedFile() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        let original = try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown)
        // A synchronized copy from another device that references the same file.
        let copy = DocumentItem(
            title: "Synced copy", originalFileName: original.originalFileName, contentType: original.contentType,
            byteCount: original.byteCount, sha256: original.sha256, storageKey: original.storageKey,
            createdAt: harness.clock.now(), updatedAt: harness.clock.now()
        )
        try await harness.database.write { db in try DocumentRepository(db).upsertRow(copy) }

        try await harness.documents.delete(original.id)
        #expect(storage.removalCount == 0)
        #expect(try await harness.documents.data(for: copy.id) == markdown)
        try await harness.documents.delete(copy.id)
        #expect(storage.base.keys.isEmpty)
    }

    @Test("a failed file removal is logged and does not undo the deletion")
    func failedRemovalIsLogged() async throws {
        let storage = CountingStorage(failRemovals: true)
        let harness = try await KnowledgeHarness.make(storage: storage)
        let document = try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown)
        try await harness.documents.delete(document.id)
        #expect(try await harness.documents.document(document.id) == nil)
        #expect(storage.removalCount == 1)
        #expect(harness.environment.logs.entries(atLeast: .error).contains { $0.message == "Document file could not be removed" })
    }

    @Test("importing into a missing collection fails and cleans up the written file")
    func importIntoMissingCollection() async throws {
        let storage = CountingStorage()
        let harness = try await KnowledgeHarness.make(storage: storage)
        await #expect(throws: DatabaseError.self) {
            try await harness.documents.import(data: markdown, fileName: "notes.md", contentType: DocumentContentType.markdown, collectionID: NoteCollection.ID())
        }
        #expect(storage.writeCount == 1)
        #expect(storage.base.keys.isEmpty)
        #expect(try await harness.documents.allDocuments().isEmpty)
        #expect(try await harness.changes().isEmpty)
    }

    @Test("input validation for imports and renames")
    func validation() async throws {
        let harness = try await KnowledgeHarness.make()
        await #expect(throws: ValidationError.self) {
            try await harness.documents.import(data: markdown, fileName: "  ", contentType: DocumentContentType.markdown)
        }
        await #expect(throws: ValidationError.self) {
            try await harness.documents.import(data: markdown, fileName: "a.md", contentType: "")
        }
        let document = try await harness.documents.import(data: markdown, fileName: "a.md", contentType: DocumentContentType.markdown)
        await #expect(throws: ValidationError.self) { try await harness.documents.rename(document.id, to: " ") }
        await #expect(throws: DatabaseError.self) { try await harness.documents.data(for: DocumentItem.ID()) }
    }

    @Test("rename, tags and move update the document and can be queried")
    func editAndQuery() async throws {
        let harness = try await KnowledgeHarness.make()
        let folder = try await harness.collections.create(name: "Folder")
        let text = try await harness.documents.import(data: markdown, fileName: "a.md", contentType: DocumentContentType.markdown)
        harness.clock.advance(by: 10)
        let image = try await harness.documents.import(data: Data([0x89, 0x50, 0x4E, 0x47]), fileName: "b.png", contentType: DocumentContentType.png)
        let checkpoint = harness.clock.now()
        let recorder = harness.recorder()
        harness.clock.advance(by: 10)

        #expect(try await harness.documents.rename(text.id, to: "Zeta").title == "Zeta")
        #expect(try await harness.documents.setTags(text.id, ["#Project", "project", "Q4 Plan"]).tags == ["project", "q4-plan"])
        #expect(try await harness.documents.move(text.id, to: folder.id).collectionID == folder.id)
        await #expect(throws: DatabaseError.self) { try await harness.documents.move(text.id, to: NoteCollection.ID()) }
        #expect(await recorder.waitForEvents(3).map(\.name) == Array(repeating: KnowledgeEvents.documentUpdated, count: 3))

        #expect(try await harness.documents.documents().map(\.id) == [text.id, image.id])
        #expect(try await harness.documents.documents(query: DocumentQuery(sort: .title)).map(\.title) == ["b", "Zeta"])
        #expect(try await harness.documents.documents(query: DocumentQuery(collectionID: folder.id)).map(\.id) == [text.id])
        #expect(try await harness.documents.documents(query: DocumentQuery(tag: "PROJECT")).map(\.id) == [text.id])
        #expect(try await harness.documents.documents(query: DocumentQuery(contentType: DocumentContentType.png)).map(\.id) == [image.id])
        #expect(try await harness.documents.documents(query: DocumentQuery(sort: .created, limit: 1)).map(\.id) == [image.id])
        #expect(try await harness.documents.documents(updatedSince: checkpoint).map(\.id) == [text.id])
    }
}
