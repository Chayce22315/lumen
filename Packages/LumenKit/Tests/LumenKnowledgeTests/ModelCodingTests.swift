import Foundation
import Testing
import LumenFoundation
import LumenKnowledge
import LumenTestSupport

@Suite("Model coding")
struct ModelCodingTests {
    let date = ManualTimeSource.referenceDate

    @Test("models round-trip through the shared JSON coders")
    func roundTrip() throws {
        let collection = NoteCollection(name: "Work", sortOrder: 2, symbolName: "folder", createdAt: date, updatedAt: date)
        let note = Note(title: "Plan", body: "# Plan\n#tag", collectionID: collection.id, tags: ["tag"], isPinned: true, createdAt: date, updatedAt: date)
        let document = DocumentItem(
            title: "Scan", originalFileName: "scan.pdf", contentType: DocumentContentType.pdf, byteCount: 42,
            sha256: String(repeating: "0", count: 64), storageKey: "x.pdf", collectionID: collection.id, tags: ["a"],
            createdAt: date, updatedAt: date
        )
        let version = NoteVersion(noteID: note.id, title: "Plan", body: "v1", savedAt: date)
        let link = EntityLink(source: note.reference, position: 1, target: nil, targetTitle: "Other", label: "o", kind: .wikiLink)

        #expect(try JSONCoding.decode(Note.self, from: JSONCoding.encodeString(note)) == note)
        #expect(try JSONCoding.decode(NoteCollection.self, from: JSONCoding.encodeString(collection)) == collection)
        #expect(try JSONCoding.decode(DocumentItem.self, from: JSONCoding.encodeString(document)) == document)
        #expect(try JSONCoding.decode(NoteVersion.self, from: JSONCoding.encodeString(version)) == version)
        #expect(try JSONCoding.decode(EntityLink.self, from: JSONCoding.encodeString(link)) == link)
    }

    @Test("snapshots missing later fields decode with defaults")
    func defaults() throws {
        let noteID = UUID()
        let note = try JSONCoding.decode(Note.self, from: #"{"id":"\#(noteID.uuidString)","createdAt":1795251600}"#)
        #expect(note.id.rawValue == noteID)
        #expect(note.title == "")
        #expect(note.body == "")
        #expect(note.tags.isEmpty)
        #expect(!note.isPinned && !note.isArchived)
        #expect(note.collectionID == nil)
        #expect(note.updatedAt == note.createdAt)

        let collection = try JSONCoding.decode(NoteCollection.self, from: #"{"id":"\#(UUID().uuidString)","name":"N","createdAt":0}"#)
        #expect(collection.sortOrder == 0)
        #expect(collection.symbolName == nil)

        let document = try JSONCoding.decode(
            DocumentItem.self,
            from: #"{"id":"\#(UUID().uuidString)","sha256":"ff","storageKey":"ff.bin","originalFileName":"a.bin","createdAt":0}"#
        )
        #expect(document.title == "a.bin")
        #expect(document.contentType == DocumentContentType.data)
        #expect(document.tags.isEmpty)
        #expect(document.extractedText == nil)

        let source = try JSONCoding.encodeString(EntityReference(kind: .note, id: UUID()))
        let link = try JSONCoding.decode(EntityLink.self, from: #"{"source":\#(source)}"#)
        #expect(link.kind == .wikiLink)
        #expect(link.position == 0)
        #expect(!link.isResolved)
    }

    @Test("note excerpt and word count come from the Markdown plain text")
    func noteDerivedValues() {
        let body = "# Heading\n\nSome **bold** text with a [link](https://x.y).\n\n- [ ] task item"
        let note = Note(title: "T", body: body, createdAt: date, updatedAt: date)
        #expect(note.excerpt == "Heading Some bold text with a link. task item")
        #expect(note.excerpt(maximumLength: 12) == "Heading Som…")
        #expect(note.wordCount == 9)
        #expect(note.reference == EntityReference(kind: .note, id: note.id))
        #expect(EntityKind.note.rawValue == "note" && EntityKind.document.rawValue == "document" && EntityKind.collection.rawValue == "collection")
    }

    @Test("event names follow module.entity.verb")
    func eventNames() {
        #expect(KnowledgeEvents.all.count == 11)
        #expect(KnowledgeEvents.all.allSatisfy { $0.module == "knowledge" && $0.rawValue.split(separator: ".").count == 3 })
        #expect(KnowledgeEvents.noteRestored.rawValue == "knowledge.note.restored")
        #expect(KnowledgeEvents.documentImported.rawValue == "knowledge.document.imported")
        #expect(KnowledgeEvents.collectionDeleted.rawValue == "knowledge.collection.deleted")
    }
}
