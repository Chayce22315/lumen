import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenSearch
import LumenTestSupport

final class FakeSource: SearchableSource {
    let kind: EntityKind
    let documents = Mutex<[UUID: SearchDocument]>([:])
    let failing = Mutex(false)

    init(kind: EntityKind) {
        self.kind = kind
    }

    struct Failure: Error {}

    func put(_ document: SearchDocument) {
        documents.withLock { $0[document.reference.id] = document }
    }

    func remove(_ id: UUID) {
        _ = documents.withLock { $0.removeValue(forKey: id) }
    }

    func document(for id: UUID) async throws -> SearchDocument? {
        if failing.withLock({ $0 }) { throw Failure() }
        return documents.withLock { $0[id] }
    }

    func allDocuments() async throws -> [SearchDocument] {
        documents.withLock { Array($0.values) }
    }
}

struct SearchHarness {
    let environment: CoreTestEnvironment
    let index: SearchIndex
    let commands: CommandRegistry
    let service: SearchService

    static func make() async throws -> SearchHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [SearchIndex.schema])
        let index = SearchIndex(database: environment.database, timeSource: environment.clock)
        let commands = CommandRegistry()
        let service = SearchService(index: index, commands: commands, database: environment.database, timeSource: environment.clock)
        return SearchHarness(environment: environment, index: index, commands: commands, service: service)
    }

    func document(_ kind: EntityKind, _ title: String, body: String = "", tags: [String] = [], ageDays: Double = 0) -> SearchDocument {
        SearchDocument(reference: EntityReference(kind: kind, id: UUID()), title: title, subtitle: kind.rawValue, body: body, tags: tags,
                       updatedAt: environment.clock.now().addingTimeInterval(-ageDays * 86_400))
    }
}

@Suite("SearchIndex and SearchService")
struct SearchServiceTests {
    @Test("finds by prefix, ignores accents and ranks title matches first")
    func basicSearch() async throws {
        let harness = try await SearchHarness.make()
        let exact = harness.document("note", "Budget")
        let body = harness.document("note", "Planning", body: "We revisit the budget every quarter.")
        let accented = harness.document("task", "Réserver le café")
        try await harness.index.upsert([exact, body, accented, harness.document("task", "Unrelated")])

        let results = try await harness.service.search(SearchQuery(text: "budg"))
        #expect(results.map(\.reference) == [exact.reference, body.reference])
        #expect(results[0].titleHighlights == [HighlightRange(offset: 0, length: 4)])
        #expect(results[1].snippet?.text.contains("budget") == true)

        #expect(try await harness.service.search(SearchQuery(text: "reserver cafe")).map(\.reference) == [accented.reference])
        #expect(try await harness.service.search(SearchQuery(text: "   ")).isEmpty)
    }

    @Test("kind and tag filters")
    func filters() async throws {
        let harness = try await SearchHarness.make()
        let note = harness.document("note", "Trip ideas", tags: ["travel"])
        let task = harness.document("task", "Trip booking", tags: ["travel", "urgent"])
        try await harness.index.upsert([note, task])
        #expect(try await harness.service.search(SearchQuery(text: "trip", kinds: ["task"])).map(\.reference) == [task.reference])
        #expect(try await harness.service.search(SearchQuery(text: "trip", tags: ["urgent"])).map(\.reference) == [task.reference])
        #expect(try await harness.service.search(SearchQuery(text: "trip", kinds: [])).isEmpty)
        #expect(try await harness.service.search(SearchQuery(text: "travel")).count == 2)
    }

    @Test("upserting replaces and removing deletes")
    func upsertAndRemove() async throws {
        let harness = try await SearchHarness.make()
        var document = harness.document("note", "Draft")
        try await harness.index.upsert(document)
        document.title = "Final copy"
        try await harness.index.upsert(document)
        #expect(try await harness.service.search(SearchQuery(text: "draft")).isEmpty)
        #expect(try await harness.service.search(SearchQuery(text: "final")).count == 1)
        #expect(try await harness.index.documentCount() == 1)
        try await harness.index.remove(document.reference)
        #expect(try await harness.index.documentCount() == 0)
    }

    @Test("the indexer follows events, removes deleted entities and rebuilds")
    func indexer() async throws {
        let harness = try await SearchHarness.make()
        let source = FakeSource(kind: "note")
        let indexer = SearchIndexer(index: harness.index, events: harness.environment.events, logger: harness.environment.logger("search"))
        await indexer.register(source)
        await indexer.start()

        let document = harness.document("note", "Garden plan")
        source.put(document)
        harness.environment.events.publish(DomainEvent(name: "knowledge.note.created", entity: document.reference, occurredAt: harness.environment.clock.now()))
        await indexer.waitForProcessedEvents(1)
        #expect(try await harness.service.search(SearchQuery(text: "garden")).count == 1)

        source.remove(document.reference.id)
        harness.environment.events.publish(DomainEvent(name: "knowledge.note.deleted", entity: document.reference, occurredAt: harness.environment.clock.now()))
        await indexer.waitForProcessedEvents(2)
        #expect(try await harness.index.documentCount() == 0)

        // Events for kinds without a source are ignored.
        harness.environment.events.publish(DomainEvent(name: "organization.task.created", entity: EntityReference(kind: "task", id: UUID()), occurredAt: harness.environment.clock.now()))

        source.put(harness.document("note", "One"))
        source.put(harness.document("note", "Two"))
        #expect(await indexer.rebuildAll() == 2)
        #expect(try await harness.index.documentCount(kind: "note") == 2)
        await indexer.stop()
    }

    @Test("source failures are logged, not thrown")
    func indexerFailure() async throws {
        let harness = try await SearchHarness.make()
        let source = FakeSource(kind: "note")
        source.failing.withLock { $0 = true }
        let indexer = SearchIndexer(index: harness.index, events: harness.environment.events, logger: harness.environment.logger("search"))
        await indexer.register(source)
        await indexer.reindex(EntityReference(kind: "note", id: UUID()))
        #expect(harness.environment.logs.entries(atLeast: .error).count == 1)
    }

    @Test("history records, deduplicates case-insensitively, filters by prefix and clears")
    func history() async throws {
        let harness = try await SearchHarness.make()
        try await harness.service.recordSearch("Budget")
        harness.environment.clock.advance(by: 10)
        try await harness.service.recordSearch("budget")
        harness.environment.clock.advance(by: 10)
        try await harness.service.recordSearch("Board meeting")
        try await harness.service.recordSearch("   ")
        let all = try await harness.service.history()
        #expect(all.map(\.query) == ["Board meeting", "budget"])
        #expect(all.last?.useCount == 2)
        #expect(try await harness.service.history(matching: "bu").map(\.query) == ["budget"])
        try await harness.service.removeHistoryEntry("BUDGET")
        #expect(try await harness.service.history().map(\.query) == ["Board meeting"])
        try await harness.service.clearHistory()
        #expect(try await harness.service.history().isEmpty)
    }

    @Test("palette combines commands, content and history")
    func palette() async throws {
        let harness = try await SearchHarness.make()
        harness.commands.register(PaletteCommand(id: "task.new", title: "New task", symbolName: "plus", keywords: ["add", "todo"], category: "Create", isSuggested: true))
        harness.commands.register(PaletteCommand(id: "insights.open", title: "Open insights", symbolName: "chart.bar", keywords: ["analytics"], category: "Navigate"))
        try await harness.index.upsert(harness.document("task", "New kitchen tiles"))

        let empty = try await harness.service.palette("")
        #expect(empty.commands.first?.command.id == "task.new")
        #expect(empty.results.isEmpty)

        let typed = try await harness.service.palette("new")
        #expect(typed.commands.map(\.command.id).first == "task.new")
        #expect(typed.results.map(\.title) == ["New kitchen tiles"])

        #expect(harness.commands.search("analytics").map(\.command.id) == ["insights.open"])
        harness.commands.unregister(prefix: "insights.")
        #expect(harness.commands.search("analytics").isEmpty)
    }
}
