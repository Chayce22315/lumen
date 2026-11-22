import Foundation
import Testing
import LumenFoundation
import LumenKnowledge
import LumenTestSupport

@Suite("NoteService links and backlinks")
struct NoteLinkTests {
    @Test("outgoing links keep order, aliases and mentions, resolving titles to notes")
    func outgoingLinks() async throws {
        let harness = try await KnowledgeHarness.make()
        let roadmap = try await harness.notes.create(title: "Roadmap")
        let taskID = UUID()
        let source = try await harness.notes.create(
            title: "Hub",
            body: "See [[roadmap|the roadmap]], [[Nowhere]] and [[task:\(taskID.uuidString)|call]]. `[[Ignored]]`"
        )
        let links = try await harness.notes.outgoingLinks(from: source.id)
        #expect(links.map(\.position) == [0, 1, 2])
        #expect(links.map(\.kind) == [.wikiLink, .wikiLink, .entityMention])
        #expect(links.map(\.target) == [roadmap.reference, nil, EntityReference(kind: "task", id: taskID)])
        #expect(links.map(\.label) == ["the roadmap", nil, "call"])
        #expect(links.map(\.targetTitle) == ["roadmap", "Nowhere", "task:\(taskID.uuidString)"])
        #expect(links.allSatisfy { $0.source == source.reference })
        #expect(links[0].displayText == "the roadmap")
    }

    @Test("backlinks include resolved links and links to the target written as entity mentions")
    func resolvedBacklinks() async throws {
        let harness = try await KnowledgeHarness.make()
        let target = try await harness.notes.create(title: "Target")
        let byTitle = try await harness.notes.create(title: "By title", body: "[[Target]]")
        harness.clock.advance(by: 10)
        let byMention = try await harness.notes.create(title: "By mention", body: "[[note:\(target.id.uuidString)]]")
        let backlinks = try await harness.notes.backlinks(to: target.reference)
        #expect(backlinks.map(\.source) == [byMention.reference, byTitle.reference])
        #expect(try await harness.notes.backlinkingNotes(to: target.reference).map(\.id) == [byMention.id, byTitle.id])
    }

    @Test("unresolved title links count as backlinks once a note with that title exists")
    func unresolvedTitleLinks() async throws {
        let harness = try await KnowledgeHarness.make()
        let source = try await harness.notes.create(title: "Source", body: "Later: [[Future Plans]]")
        #expect(try await harness.notes.outgoingLinks(from: source.id).first?.target == nil)

        harness.clock.advance(by: 10)
        let future = try await harness.notes.create(title: "future  plans")
        let backlinks = try await harness.notes.backlinks(to: future.reference)
        #expect(backlinks.map(\.source) == [source.reference])
        #expect(backlinks.first?.isResolved == false)
        // Outgoing links resolve the stored unresolved link against current titles.
        #expect(try await harness.notes.outgoingLinks(from: source.id).first?.target == future.reference)
    }

    @Test("with duplicate titles the most recently updated note wins resolution and title backlinks")
    func duplicateTitles() async throws {
        let harness = try await KnowledgeHarness.make()
        let source = try await harness.notes.create(title: "Source", body: "[[Dup]]")
        harness.clock.advance(by: 10)
        let older = try await harness.notes.create(title: "Dup")
        harness.clock.advance(by: 10)
        let newer = try await harness.notes.create(title: "dup")

        #expect(try await harness.notes.resolveTitle("DUP")?.id == newer.id)
        #expect(try await harness.notes.backlinks(to: newer.reference).map(\.source) == [source.reference])
        #expect(try await harness.notes.backlinks(to: older.reference).isEmpty)

        harness.clock.advance(by: 10)
        try await harness.notes.update(older.id, body: "edited")
        #expect(try await harness.notes.resolveTitle("Dup")?.id == older.id)
        #expect(try await harness.notes.backlinks(to: older.reference).map(\.source) == [source.reference])
        #expect(try await harness.notes.backlinks(to: newer.reference).isEmpty)
    }

    @Test("title resolution ignores case, diacritics and extra whitespace")
    func resolveTitle() async throws {
        let harness = try await KnowledgeHarness.make()
        let note = try await harness.notes.create(title: "Café Notes")
        #expect(try await harness.notes.resolveTitle("  cafe   NOTES ")?.id == note.id)
        #expect(try await harness.notes.resolveTitle("Cafe Note") == nil)
        #expect(try await harness.notes.resolveTitle("   ") == nil)
    }

    @Test("mentions of other entities are found as backlinks of that entity")
    func entityMentionBacklinks() async throws {
        let harness = try await KnowledgeHarness.make()
        let task = EntityReference(kind: "task", id: UUID())
        let note = try await harness.notes.create(title: "Daily", body: "- [ ] do [[\(task.uri)]]")
        #expect(try await harness.notes.backlinks(to: task).map(\.source) == [note.reference])
        #expect(try await harness.notes.backlinks(to: EntityReference(kind: "task", id: UUID())).isEmpty)
    }

    @Test("a resolved link sticks to its note through renames and later edits of the source")
    func stickyResolution() async throws {
        let harness = try await KnowledgeHarness.make()
        let target = try await harness.notes.create(title: "Spec")
        let source = try await harness.notes.create(title: "Source", body: "Read [[Spec]]")
        try await harness.notes.update(target.id, title: "Specification")
        try await harness.notes.update(source.id, body: "Read [[Spec]] carefully")
        #expect(try await harness.notes.outgoingLinks(from: source.id).first?.target == target.reference)
        #expect(try await harness.notes.backlinks(to: target.reference).map(\.source) == [source.reference])
    }

    @Test("deleting a target turns its title links back into unresolved links")
    func deletingTargetUnresolves() async throws {
        let harness = try await KnowledgeHarness.make()
        let first = try await harness.notes.create(title: "Topic")
        let source = try await harness.notes.create(title: "Source", body: "[[Topic]]")
        let mention = try await harness.notes.create(title: "Mention", body: "[[note:\(first.id.uuidString)]]")
        try await harness.notes.delete(first.id)

        #expect(try await harness.notes.outgoingLinks(from: source.id).first?.target == nil)
        // Explicit mentions keep their reference even though the note is gone.
        #expect(try await harness.notes.outgoingLinks(from: mention.id).first?.target == first.reference)

        harness.clock.advance(by: 10)
        let replacement = try await harness.notes.create(title: "topic")
        #expect(try await harness.notes.backlinks(to: replacement.reference).map(\.source) == [source.reference])
    }

    @Test("editing the body replaces the link index")
    func linksFollowBody() async throws {
        let harness = try await KnowledgeHarness.make()
        let a = try await harness.notes.create(title: "A")
        let b = try await harness.notes.create(title: "B")
        let source = try await harness.notes.create(title: "S", body: "[[A]] [[A|again]]")
        #expect(try await harness.notes.backlinks(to: a.reference).count == 2)
        #expect(try await harness.notes.backlinkingNotes(to: a.reference).map(\.id) == [source.id])

        try await harness.notes.update(source.id, body: "now [[B]] only")
        #expect(try await harness.notes.backlinks(to: a.reference).isEmpty)
        #expect(try await harness.notes.backlinks(to: b.reference).map(\.source) == [source.reference])
        #expect(try await harness.notes.outgoingLinks(from: source.id).map(\.position) == [0])
    }
}
