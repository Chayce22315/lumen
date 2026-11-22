import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenKnowledge
import LumenTestSupport

@Suite("TagService")
struct TagServiceTests {
    @Test("allTags counts notes and documents, most used first, then by name")
    func allTags() async throws {
        let harness = try await KnowledgeHarness.make()
        try await harness.notes.create(title: "A", body: "#work #ideas")
        try await harness.notes.create(title: "B", body: "#work", tags: ["zeta"])
        let archived = try await harness.notes.create(title: "C", tags: ["alpha"])
        try await harness.notes.archive(archived.id)
        try await harness.documents.import(data: Data("x".utf8), fileName: "x.txt", contentType: DocumentContentType.plainText, tags: ["ideas", "docs"])

        #expect(try await harness.tags.allTags() == [
            TagUsage(tag: "ideas", noteCount: 1, documentCount: 1),
            TagUsage(tag: "work", noteCount: 2, documentCount: 0),
            TagUsage(tag: "alpha", noteCount: 1, documentCount: 0),
            TagUsage(tag: "docs", noteCount: 0, documentCount: 1),
            TagUsage(tag: "zeta", noteCount: 1, documentCount: 0),
        ])
    }

    @Test("rename applies to notes and documents, rewriting hashtags in bodies")
    func rename() async throws {
        let harness = try await KnowledgeHarness.make()
        let hashtagNote = try await harness.notes.create(title: "H", body: "Plan #Work today, not `#work`")
        let explicitNote = try await harness.notes.create(title: "E", tags: ["work", "other"])
        let untouched = try await harness.notes.create(title: "U", tags: ["other"])
        let document = try await harness.documents.import(data: Data("d".utf8), fileName: "d.txt", contentType: DocumentContentType.plainText, tags: ["work"])

        let recorder = harness.recorder()
        harness.clock.advance(by: 10)
        let summary = try await harness.tags.renameTag("#work", to: "Job")
        #expect(summary == TagChangeSummary(notesUpdated: 2, documentsUpdated: 1))

        let renamedHashtag = try #require(try await harness.notes.note(hashtagNote.id))
        #expect(renamedHashtag.body == "Plan #job today, not `#work`")
        #expect(renamedHashtag.tags == ["job"])
        #expect(try await harness.notes.note(explicitNote.id)?.tags == ["job", "other"])
        #expect(try await harness.notes.note(untouched.id) == untouched)
        #expect(try await harness.documents.document(document.id)?.tags == ["job"])

        #expect(try await harness.changes(for: hashtagNote.reference).count == 2)
        #expect(try await harness.changes(for: untouched.reference).count == 1)
        #expect(try await harness.changes(for: document.reference).count == 2)
        let names = await recorder.waitForEvents(3).map(\.name)
        #expect(names.sorted() == [KnowledgeEvents.documentUpdated, KnowledgeEvents.noteUpdated, KnowledgeEvents.noteUpdated])

        // The renamed tag does not come back from the old hashtag on the next edit.
        let edited = try await harness.notes.update(hashtagNote.id, body: renamedHashtag.body + "!")
        #expect(edited.tags == ["job"])
    }

    @Test("merge folds several tags into one without duplicates")
    func merge() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "N", body: "#todo and #to-do", tags: ["tasks", "keep"])
        let summary = try await harness.tags.mergeTags(["todo", "to-do", "tasks"], into: "tasks")
        #expect(summary.notesUpdated == 1)
        let merged = try #require(try await harness.notes.note(note.id))
        #expect(merged.body == "#tasks and #tasks")
        #expect(merged.tags == ["tasks", "keep"])
        #expect(try await harness.tags.allTags().map(\.tag) == ["keep", "tasks"])
    }

    @Test("a target that can't be a hashtag is rejected only when bodies use the hashtag")
    func nonHashtagTarget() async throws {
        let harness = try await KnowledgeHarness.make()
        let hashtagNote = try await harness.notes.create(title: "H", body: "#cpp rocks")
        await #expect(throws: ValidationError.self) { try await harness.tags.renameTag("cpp", to: "c++") }
        #expect(try await harness.notes.note(hashtagNote.id) == hashtagNote)

        let explicitOnly = try await harness.notes.create(title: "E", tags: ["lang"])
        try await harness.tags.renameTag("lang", to: "c++")
        #expect(try await harness.notes.note(explicitOnly.id)?.tags == ["c++"])
    }

    @Test("renaming to the same tag does nothing; an empty target is invalid")
    func noOpAndValidation() async throws {
        let harness = try await KnowledgeHarness.make()
        try await harness.notes.create(title: "N", tags: ["same"])
        #expect(try await harness.tags.renameTag("Same", to: "#same") == TagChangeSummary())
        #expect(try await harness.tags.renameTag("missing", to: "other") == TagChangeSummary())
        await #expect(throws: ValidationError.self) { try await harness.tags.renameTag("same", to: "  #  ") }
        #expect(try await harness.changes().count == 1)
    }
}
