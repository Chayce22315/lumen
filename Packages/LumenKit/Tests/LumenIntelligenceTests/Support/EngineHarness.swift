import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

/// A provider that replays a script of completions.
final class FakeProvider: ModelProvider {
    enum Step: Sendable {
        case reply([CompletionEvent])
        case fail(ProviderError)
        case failAfter([CompletionEvent], ProviderError)
        /// Yields the events, then stays open until the consumer cancels.
        case hang([CompletionEvent])
        /// Decides from the request (e.g. its `toolChoice`).
        case dynamic(@Sendable (CompletionRequest) -> [CompletionEvent])
    }

    let id: ProviderID
    let displayName: String
    let requiresAPIKey: Bool
    let models: [ModelDescriptor]
    private let script = Mutex<[Step]>([])
    private let recorded = Mutex<[CompletionRequest]>([])
    private let cancellations = Mutex(0)
    private let repeating: Step?

    init(id: ProviderID = .anthropic, requiresAPIKey: Bool = true, models: [ModelDescriptor]? = nil, script: [Step] = [], repeating: Step? = nil) {
        self.id = id
        self.displayName = id == .anthropic ? "Anthropic" : id.rawValue
        self.requiresAPIKey = requiresAPIKey
        self.models = models ?? [ModelDescriptor(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", providerID: id, contextWindow: 1_000_000, maxOutputTokens: 128_000)]
        self.repeating = repeating
        self.script.withLock { $0 = script }
    }

    var requests: [CompletionRequest] { recorded.withLock { $0 } }
    var cancelledStreams: Int { cancellations.withLock { $0 } }

    func availableModels() async throws -> [ModelDescriptor] { models }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        recorded.withLock { $0.append(request) }
        let step = script.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? repeating ?? .reply(Self.text("OK"))
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] termination in
                if case .cancelled = termination {
                    cancellations.withLock { $0 += 1 }
                }
            }
            switch step {
            case .reply(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .failAfter(let events, let error):
                events.forEach { continuation.yield($0) }
                continuation.finish(throwing: error)
            case .hang(let events):
                events.forEach { continuation.yield($0) }
            case .dynamic(let respond):
                respond(request).forEach { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    static func text(_ text: String, usage: TokenUsage = TokenUsage(input: 100, output: 20)) -> [CompletionEvent] {
        [.usage(TokenUsage(input: usage.input, output: 1, cacheCreation: usage.cacheCreation, cacheRead: usage.cacheRead)), .textDelta(text), .usage(usage), .stop(.endTurn)]
    }

    static func tool(id: String, name: String, input: JSONValue, usage: TokenUsage = TokenUsage(input: 80, output: 15), reasoning: Bool = false) -> [CompletionEvent] {
        var events: [CompletionEvent] = [.usage(TokenUsage(input: usage.input, output: 1))]
        if reasoning {
            events.append(.thinking(text: "", signature: "sig-\(id)"))
        }
        events += [.textDelta("Let me check."), .toolUse(id: id, name: name, input: input), .usage(usage), .stop(.toolUse)]
        return events
    }
}

/// A tool that records its calls and answers with a fixed output (or throws, or waits).
final class RecordingTool: AssistantTool {
    enum Behavior: Sendable {
        case output(ToolOutput)
        case fail(String)
        case sleep(TimeInterval)
    }

    struct TestFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    let definition: ToolDefinition
    let isMutating: Bool
    private let behavior: Behavior
    private let calls = Mutex<[(JSONValue, ToolContext)]>([])

    init(_ name: String, isMutating: Bool = false, behavior: Behavior = .output(ToolOutput(text: "done")), schema: JSONValue? = nil) {
        self.definition = ToolDefinition(
            name: name,
            description: "Test tool \(name)",
            inputSchema: schema ?? ["type": "object", "properties": ["query": ["type": "string"]]]
        )
        self.isMutating = isMutating
        self.behavior = behavior
    }

    var inputs: [JSONValue] { calls.withLock { $0.map(\.0) } }
    var contexts: [ToolContext] { calls.withLock { $0.map(\.1) } }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        calls.withLock { $0.append((input, context)) }
        switch behavior {
        case .output(let output):
            return output
        case .fail(let reason):
            throw TestFailure(reason: reason)
        case .sleep(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ToolOutput(text: "slept")
        }
    }
}

final class ScriptedApproval: ToolApprovalHandler {
    let answer: Bool
    private let asked = Mutex<[String]>([])

    init(_ answer: Bool) {
        self.answer = answer
    }

    var requests: [String] { asked.withLock { $0 } }

    func approve(tool: ToolDefinition, input: JSONValue) async -> Bool {
        asked.withLock { $0.append(tool.name) }
        return answer
    }
}

struct FixedContext: AssistantContextProvider {
    let summary: String
    func contextSummary() async -> String? { summary }
}

final class SleepRecorder: Sendable {
    private let delays = Mutex<[TimeInterval]>([])
    var recorded: [TimeInterval] { delays.withLock { $0 } }
    func record(_ delay: TimeInterval) { delays.withLock { $0.append(delay) } }
}

struct EngineHarness {
    let environment: CoreTestEnvironment
    let secrets: InMemorySecretStore
    let providers: ProviderRegistry
    let tools: ToolRegistry
    let memory: MemoryStore
    let conversations: ConversationService
    let usage: UsageTracker
    let provider: FakeProvider
    let engine: AssistantEngine
    let sleeps: SleepRecorder
    let events: EventRecorder

    static let selection = ModelSelection(providerID: .anthropic, modelID: "claude-opus-5-5")

    static func make(
        provider: FakeProvider = FakeProvider(),
        tools: [any AssistantTool] = [],
        approval: (any ToolApprovalHandler)? = nil,
        contextProvider: (any AssistantContextProvider)? = nil,
        configuration: AssistantEngine.Configuration = .init(),
        defaultModel: ModelSelection? = EngineHarness.selection,
        keys: [ProviderID: String] = [.anthropic: ProviderFixtures.anthropicKey]
    ) async throws -> EngineHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [AssistantEngine.schema])
        let events = EventRecorder(bus: environment.events, filter: EventFilter(modules: ["intelligence"]))
        let secrets = ProviderFixtures.secrets(keys)
        let providers = ProviderRegistry([provider])
        let registry = ToolRegistry()
        for tool in tools {
            try registry.register(tool)
        }
        let logger = environment.logger("intelligence")
        let memory = MemoryStore(database: environment.database, events: environment.events, settings: environment.settings, timeSource: environment.clock, logger: logger)
        if let defaultModel {
            try await environment.settings.set(defaultModel, for: AssistantSettings.defaultModel)
        }
        let sleeps = SleepRecorder()
        let engine = AssistantEngine(
            database: environment.database,
            events: environment.events,
            settings: environment.settings,
            secrets: secrets,
            providers: providers,
            catalog: ModelCatalog(registry: providers, timeSource: environment.clock),
            tools: registry,
            memory: memory,
            approvalHandler: approval,
            contextProvider: contextProvider,
            timeSource: environment.clock,
            calendar: environment.calendar,
            logger: logger,
            configuration: configuration,
            sleep: { delay in sleeps.record(delay) }
        )
        return EngineHarness(
            environment: environment,
            secrets: secrets,
            providers: providers,
            tools: registry,
            memory: memory,
            conversations: ConversationService(database: environment.database, events: environment.events, timeSource: environment.clock, logger: logger),
            usage: UsageTracker(database: environment.database, calendar: environment.calendar, logger: logger),
            provider: provider,
            engine: engine,
            sleeps: sleeps,
            events: events
        )
    }

    /// Sends `text` and collects every update until the turn ends.
    func send(_ text: String, in conversationID: Conversation.ID) async -> [AssistantUpdate] {
        var updates: [AssistantUpdate] = []
        do {
            for try await update in await engine.send(text: text, in: conversationID) {
                updates.append(update)
            }
        } catch {
            Issue.record("The update stream threw: \(error)")
        }
        return updates
    }

    func messages(_ conversationID: Conversation.ID) async throws -> [ChatMessage] {
        try await conversations.messages(in: conversationID)
    }

    /// Waits (bounded) until `condition` holds.
    static func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

extension Array where Element == AssistantUpdate {
    var completedMessages: [ChatMessage] {
        compactMap { if case .completed(let message) = $0 { return message } else { return nil } }
    }

    var failure: ErrorPresentation? {
        compactMap { if case .failed(let presentation) = $0 { return presentation } else { return nil } }.first
    }

    var deltas: String {
        compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined()
    }
}
