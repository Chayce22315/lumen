import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

@Suite("MemoryStore")
struct MemoryStoreTests {
    func make() async throws -> (MemoryStore, CoreTestEnvironment) {
        let environment = try await CoreTestEnvironment.make(schemas: [IntelligenceSchema.schema])
        let store = MemoryStore(database: environment.database, events: environment.events, settings: environment.settings, timeSource: environment.clock, logger: environment.logger("intelligence"))
        return (store, environment)
    }

    @Test("adds, updates, disables and deletes memories, recording each change for sync")
    func crud() async throws {
        let (store, environment) = try await make()
        let recorder = EventRecorder(bus: environment.events, filter: EventFilter(modules: ["intelligence"]))
        let memory = try await store.add("  Prefers metric units  ")
        #expect(memory.content == "Prefers metric units")
        environment.clock.advance(by: 60)
        let updated = try await store.update(memory.id, content: "Prefers metric units and 24h time")
        #expect(updated.updatedAt == environment.clock.now())
        let disabled = try await store.setEnabled(false, for: memory.id)
        #expect(!disabled.isEnabled)
        #expect(try await store.memories(includeDisabled: false).isEmpty)
        #expect(try await store.memories().count == 1)
        try await store.delete(memory.id)
        #expect(try await store.memories().isEmpty)

        let history = try await environment.database.read { db in try db.history(of: memory.reference) }
        #expect(history.map(\.operation) == [.upsert, .upsert, .upsert, .delete])
        #expect(history.first?.payload?["content"] == "Prefers metric units")
        let names = await recorder.waitForEvents(4).map(\.name)
        #expect(names == [IntelligenceEvents.memoryAdded, IntelligenceEvents.memoryUpdated, IntelligenceEvents.memoryUpdated, IntelligenceEvents.memoryDeleted])
    }

    @Test("the global switch hides every memory from the assistant")
    func globalToggle() async throws {
        let (store, _) = try await make()
        try await store.add("Fact")
        #expect(await store.isMemoryEnabled())
        #expect(try await store.activeMemories().count == 1)
        try await store.setMemoryEnabled(false)
        #expect(!(await store.isMemoryEnabled()))
        #expect(try await store.activeMemories().isEmpty)
        #expect(try await store.memories().count == 1)
    }

    @Test("clearAll deletes everything with a change record per memory")
    func clearAll() async throws {
        let (store, environment) = try await make()
        let first = try await store.add("One")
        let second = try await store.add("Two", source: .assistant)
        try await store.clearAll()
        #expect(try await store.memories().isEmpty)
        let deletions = try await environment.database.read { db in try db.changes(after: 0) }.filter { $0.operation == .delete }
        #expect(Set(deletions.map(\.entity.id)) == [first.id.rawValue, second.id.rawValue])
    }

    @Test("blank and oversized memories are rejected; missing ones are not found")
    func validation() async throws {
        let (store, _) = try await make()
        await #expect(throws: ValidationError.self) { try await store.add("   ") }
        await #expect(throws: ValidationError.self) { try await store.add(String(repeating: "x", count: 1_001)) }
        await #expect(throws: DatabaseError.self) { try await store.delete(MemoryItem.ID()) }
    }

    @Test("upsertRow and deleteRow apply synced memories without new change records")
    func syncRows() async throws {
        let (store, environment) = try await make()
        let remote = MemoryItem(content: "From another device", source: .user, createdAt: environment.clock.now())
        try await environment.database.write { db in try MemoryRepository.upsertRow(remote, in: db) }
        #expect(try await store.memory(remote.id) == remote)
        try await environment.database.write { db in try MemoryRepository.deleteRow(remote.id, in: db) }
        #expect(try await store.memory(remote.id) == nil)
        #expect(try await environment.database.read { db in try db.latestChangeSequence() } == 0)
    }
}

@Suite("ConversationService")
struct ConversationServiceTests {
    func make() async throws -> (ConversationService, CoreTestEnvironment) {
        let environment = try await CoreTestEnvironment.make(schemas: [IntelligenceSchema.schema])
        return (ConversationService(database: environment.database, events: environment.events, timeSource: environment.clock, logger: environment.logger("intelligence")), environment)
    }

    @Test("creates, renames and lists conversations pinned first, then most recent")
    func listing() async throws {
        let (service, environment) = try await make()
        let first = try await service.create(title: "First")
        environment.clock.advance(by: 10)
        let second = try await service.create()
        environment.clock.advance(by: 10)
        let third = try await service.create(title: "Third")
        try await service.setPinned(true, for: first.id)
        #expect(try await service.list().map(\.id) == [first.id, third.id, second.id])
        #expect(second.displayTitle == "New conversation")

        let renamed = try await service.rename(second.id, to: "  Trip   planning ")
        #expect(renamed.title == "Trip planning")
        try await service.setArchived(true, for: third.id)
        #expect(try await service.list().map(\.id) == [first.id, second.id])
        #expect(try await service.list(includeArchived: true).count == 3)
    }

    @Test("deleting removes the conversation and its messages, recording every deletion")
    func deletion() async throws {
        let (service, environment) = try await make()
        let recorder = EventRecorder(bus: environment.events, filter: EventFilter(modules: ["intelligence"]))
        let conversation = try await service.create(title: "Doomed")
        let message = ChatMessage(conversationID: conversation.id, role: .user, blocks: [.text("hi")], createdAt: environment.clock.now())
        try await environment.database.write { db in try MessageRepository.save(message, in: db) }
        try await service.delete(conversation.id)
        #expect(try await service.conversation(conversation.id) == nil)
        #expect(try await service.messages(in: conversation.id).isEmpty)
        let deleted = try await environment.database.read { db in try db.changes(after: 0) }.filter { $0.operation == .delete }.map(\.entity)
        #expect(Set(deleted) == [conversation.reference, message.reference])
        #expect(await recorder.waitForEvents(2).map(\.name) == [IntelligenceEvents.conversationCreated, IntelligenceEvents.conversationDeleted])
        await #expect(throws: DatabaseError.self) { try await service.delete(conversation.id) }
    }

    @Test("the per-conversation model selection can be set and cleared")
    func selection() async throws {
        let (service, _) = try await make()
        let conversation = try await service.create()
        let selection = ModelSelection(providerID: .anthropic, modelID: "claude-sonnet-5-5")
        #expect(try await service.setSelection(selection, for: conversation.id).selection == selection)
        #expect(try await service.conversation(conversation.id)?.selection == selection)
        #expect(try await service.setSelection(nil, for: conversation.id).selection == nil)
    }

    @Test("messages and conversations round-trip through their rows; sync rows write no change records")
    func rowsRoundTrip() async throws {
        let (service, environment) = try await make()
        let conversation = Conversation(title: "Synced", selection: ModelSelection(providerID: "ollama", modelID: "llama3"), createdAt: environment.clock.now(), isPinned: true)
        let message = ChatMessage(
            conversationID: conversation.id, role: .assistant,
            blocks: [.text("Done"), .toolUse(id: "t", name: "x", input: ["a": 1])],
            status: .complete, createdAt: environment.clock.now(),
            usage: TokenUsage(input: 1, output: 2), errorMessage: nil, model: conversation.selection
        )
        try await environment.database.write { db in
            try ConversationRepository.upsertRow(conversation, in: db)
            try MessageRepository.upsertRow(message, in: db)
        }
        #expect(try await service.conversation(conversation.id) == conversation)
        #expect(try await service.messages(in: conversation.id) == [message])
        #expect(try await environment.database.read { db in try db.latestChangeSequence() } == 0)
    }
}

@Suite("UsageTracker")
struct UsageTrackerTests {
    @Test("totals per day, model and provider over a date range")
    func totals() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [IntelligenceSchema.schema])
        let tracker = UsageTracker(database: environment.database, calendar: environment.calendar, logger: environment.logger("intelligence"))
        let day1 = environment.clock.now()
        let day2 = day1.addingTimeInterval(86_400)
        try await tracker.record(UsageRecord(providerID: .anthropic, modelID: "claude-opus-5-5", usage: TokenUsage(input: 100, output: 10, cacheRead: 50), recordedAt: day1))
        try await tracker.record(UsageRecord(providerID: .anthropic, modelID: "claude-haiku-5-5", usage: TokenUsage(input: 5, output: 5), recordedAt: day1))
        try await tracker.record(UsageRecord(providerID: .openAI, modelID: "gpt-5", usage: TokenUsage(input: 7, output: 3), recordedAt: day2))
        try await tracker.record(UsageRecord(providerID: .openAI, modelID: "gpt-5", usage: TokenUsage(input: 1000, output: 1000), recordedAt: day2.addingTimeInterval(86_400 * 30)))

        let range = DateInterval(start: day1.addingTimeInterval(-3_600), end: day2.addingTimeInterval(3_600))
        let byDay = try await tracker.totals(in: range, groupedBy: .day)
        #expect(byDay.map(\.day?.description) == ["2026-11-21", "2026-11-22"])
        #expect(byDay.map(\.usage) == [TokenUsage(input: 105, output: 15, cacheRead: 50), TokenUsage(input: 7, output: 3)])
        #expect(byDay.map(\.completions) == [2, 1])

        let byModel = try await tracker.totals(in: range, groupedBy: .model)
        #expect(byModel.map { "\($0.providerID?.rawValue ?? "")/\($0.modelID ?? "")" } == ["anthropic/claude-haiku-5-5", "anthropic/claude-opus-5-5", "openai/gpt-5"])

        let byProvider = try await tracker.totals(in: range, groupedBy: .provider)
        #expect(byProvider.map(\.providerID) == [.anthropic, .openAI])
        #expect(byProvider.first?.usage.total == 170)

        #expect(try await tracker.total(in: range).usage.output == 18)
        let daily = try await tracker.dailyTotals(from: try #require(CalendarDate(year: 2026, month: 11, day: 22)), through: try #require(CalendarDate(year: 2026, month: 11, day: 22)))
        #expect(daily.map(\.usage) == [TokenUsage(input: 7, output: 3)])

        try await tracker.purge(recordedBefore: day2)
        #expect(try await tracker.total(in: range).completions == 1)
    }
}

struct StaticTool: AssistantTool {
    let definition: ToolDefinition
    let isMutating: Bool

    init(_ name: String, isMutating: Bool = false) {
        self.definition = ToolDefinition(name: name, description: "Test tool", inputSchema: ["type": "object"])
        self.isMutating = isMutating
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(text: "ok")
    }
}

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("registers tools sorted by name and rejects duplicates, invalid and reserved names")
    func registration() throws {
        let registry = ToolRegistry()
        try registry.register(StaticTool("search_notes"))
        try registry.register(StaticTool("create-task", isMutating: true))
        #expect(registry.definitions.map(\.name) == ["create-task", "search_notes"])
        #expect(throws: ToolRegistryError.duplicateName("search_notes")) { try registry.register(StaticTool("search_notes")) }
        #expect(throws: ToolRegistryError.invalidName("has space")) { try registry.register(StaticTool("has space")) }
        #expect(throws: ToolRegistryError.reservedName("remember")) { try registry.register(StaticTool("remember")) }
        registry.unregister(named: "search_notes")
        #expect(registry.tool(named: "search_notes") == nil)
        #expect(registry.tool(named: "create-task")?.isMutating == true)
    }

    @Test("tool names follow the provider-wide rules")
    func names() {
        #expect(ToolDefinition.isValidName("a_b-C9"))
        #expect(!ToolDefinition.isValidName(""))
        #expect(!ToolDefinition.isValidName(String(repeating: "a", count: 65)))
        #expect(!ToolDefinition.isValidName("café"))
    }
}

final class CountingProvider: ModelProvider {
    let id: ProviderID = "counting"
    let displayName = "Counting"
    let requiresAPIKey = false
    private let calls = Mutex(0)
    private let failing = Mutex(false)

    var callCount: Int { calls.withLock { $0 } }

    func setFailing(_ value: Bool) {
        failing.withLock { $0 = value }
    }

    func availableModels() async throws -> [ModelDescriptor] {
        let count = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if failing.withLock({ $0 }) { throw ProviderError.network("down") }
        return [ModelDescriptor(id: "model-\(count)", displayName: "Model \(count)", providerID: id)]
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("ProviderRegistry and ModelCatalog")
struct ModelCatalogTests {
    @Test("the registry replaces providers with the same id and keeps registration order")
    func registry() {
        let registry = ProviderRegistry([CountingProvider()])
        registry.register(StubProvider(id: "second"))
        registry.register(CountingProvider())
        #expect(registry.providers.map(\.id) == ["counting", "second"])
        registry.unregister("counting")
        #expect(registry.provider("counting") == nil)
    }

    @Test("caches model lists until they expire or are refreshed")
    func caching() async throws {
        let provider = CountingProvider()
        let clock = ManualTimeSource()
        let catalog = ModelCatalog(registry: ProviderRegistry([provider]), timeSource: clock, maxAge: 600)
        #expect(try await catalog.models(for: "counting").map(\.id) == ["model-1"])
        #expect(try await catalog.models(for: "counting").map(\.id) == ["model-1"])
        #expect(provider.callCount == 1)
        #expect(try await catalog.models(for: "counting", refresh: true).map(\.id) == ["model-2"])
        clock.advance(by: 601)
        #expect(try await catalog.models(for: "counting").map(\.id) == ["model-3"])
        await catalog.invalidate()
        #expect(await catalog.descriptor(for: ModelSelection(providerID: "counting", modelID: "model-4"))?.displayName == "Model 4")
    }

    @Test("failures are reported per provider and unknown providers are unavailable")
    func failures() async {
        let provider = CountingProvider()
        provider.setFailing(true)
        let catalog = ModelCatalog(registry: ProviderRegistry([provider]), timeSource: ManualTimeSource())
        let all = await catalog.allModels()
        if case .failure(let error)? = all["counting"] {
            #expect(error as? ProviderError == .network("down"))
        } else {
            Issue.record("expected a failure")
        }
        await #expect(throws: AssistantError.providerUnavailable("nobody")) { try await catalog.models(for: "nobody") }
        #expect(await catalog.descriptor(for: ModelSelection(providerID: "counting", modelID: "x")) == nil)
    }
}

struct StubProvider: ModelProvider {
    let id: ProviderID
    var displayName: String { id.rawValue }
    var requiresAPIKey: Bool { false }
    func availableModels() async throws -> [ModelDescriptor] { [] }
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
