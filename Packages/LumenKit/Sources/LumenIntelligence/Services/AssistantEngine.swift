import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The assistant: runs conversation turns against the selected model, executes tool calls,
/// persists every message and records token usage.
///
/// A turn: validate the configuration (nothing is persisted when no model, provider or API key
/// is set up) → persist the user message (auto-titling a new conversation) → build the system
/// prompt and fit the history → stream the completion (retrying transient failures only while
/// nothing has been received) → persist the assistant message with its usage → run requested
/// tools (approval for mutating tools, timeout, errors fed back as error results) → repeat, up to
/// `Configuration.maxToolRounds` tool rounds, after which the model must answer in text.
///
/// Cancellation — the consumer stops iterating, or `cancel(conversationID:)` — cancels the HTTP
/// stream and persists the partial text with status `.cancelled`.
public actor AssistantEngine {
    public struct Configuration: Sendable, Hashable {
        /// Tool rounds per turn before the model is asked to answer without tools.
        public var maxToolRounds: Int
        /// Seconds a single tool call may run.
        public var toolTimeout: TimeInterval
        /// Retries for failures before any output arrived.
        public var retryPolicy: RetryPolicy
        /// A server-requested delay longer than this is not waited out; the error is shown instead.
        public var maxRetryAfter: TimeInterval
        /// Upper bound on `max_tokens`, further capped by the model's own limit.
        public var maxOutputTokens: Int
        /// Assumed limits for models whose provider doesn't report them.
        public var unknownModelMaxOutputTokens: Int
        public var unknownModelContextWindow: Int
        /// Estimated tokens kept free beyond the system prompt and tool definitions, because token
        /// counts are estimates.
        public var contextSafetyMargin: Int
        /// Library items one message may carry.
        public var maxAttachmentsPerMessage: Int
        /// Characters of attachment text one message may send (further capped at half the history
        /// budget; see `AttachmentBudget`).
        public var maxAttachmentCharacters: Int

        public init(
            maxToolRounds: Int = 8,
            toolTimeout: TimeInterval = 30,
            retryPolicy: RetryPolicy = .standard,
            maxRetryAfter: TimeInterval = 60,
            maxOutputTokens: Int = 64_000,
            unknownModelMaxOutputTokens: Int = 4_096,
            unknownModelContextWindow: Int = 32_000,
            contextSafetyMargin: Int = 1_024,
            maxAttachmentsPerMessage: Int = 10,
            maxAttachmentCharacters: Int = 60_000
        ) {
            self.maxAttachmentsPerMessage = max(0, maxAttachmentsPerMessage)
            self.maxAttachmentCharacters = max(0, maxAttachmentCharacters)
            self.maxToolRounds = max(0, maxToolRounds)
            self.toolTimeout = max(0, toolTimeout)
            self.retryPolicy = retryPolicy
            self.maxRetryAfter = max(0, maxRetryAfter)
            self.maxOutputTokens = max(1, maxOutputTokens)
            self.unknownModelMaxOutputTokens = max(1, unknownModelMaxOutputTokens)
            self.unknownModelContextWindow = max(1, unknownModelContextWindow)
            self.contextSafetyMargin = max(0, contextSafetyMargin)
        }
    }

    public static let schema = IntelligenceSchema.schema

    typealias Updates = AsyncThrowingStream<AssistantUpdate, any Error>.Continuation

    struct ActiveTurn {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Everything a turn needs, resolved before anything is persisted.
    struct TurnSetup: Sendable {
        let conversationID: Conversation.ID
        let turnID: UUID
        let context: ActionContext
        let selection: ModelSelection
        let provider: any ModelProvider
        let system: String
        let tools: [String: any AssistantTool]
        let toolDefinitions: [ToolDefinition]
        let requiresApproval: Bool
        let maxTokens: Int
        let historyBudget: Int
    }

    let database: Database
    let events: EventBus
    let settings: SettingsStore
    let secrets: any SecretStore
    let providers: ProviderRegistry
    let catalog: ModelCatalog
    let tools: ToolRegistry
    let memory: MemoryStore
    let contextBuilder: ContextBuilder
    let approvalHandler: (any ToolApprovalHandler)?
    let contextProvider: (any AssistantContextProvider)?
    let attachmentResolver: (any AttachmentResolver)?
    let timeSource: any TimeSource
    let calendar: Calendar
    let logger: Logger
    let configuration: Configuration
    let sleep: @Sendable (TimeInterval) async throws -> Void

    var activeTurns: [Conversation.ID: ActiveTurn] = [:]

    public init(
        database: Database,
        events: EventBus,
        settings: SettingsStore,
        secrets: any SecretStore,
        providers: ProviderRegistry,
        catalog: ModelCatalog,
        tools: ToolRegistry,
        memory: MemoryStore,
        contextBuilder: ContextBuilder = ContextBuilder(),
        approvalHandler: (any ToolApprovalHandler)? = nil,
        contextProvider: (any AssistantContextProvider)? = nil,
        attachmentResolver: (any AttachmentResolver)? = nil,
        timeSource: any TimeSource,
        calendar: Calendar,
        logger: Logger,
        configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.database = database
        self.events = events
        self.settings = settings
        self.secrets = secrets
        self.providers = providers
        self.catalog = catalog
        self.tools = tools
        self.memory = memory
        self.contextBuilder = contextBuilder
        self.approvalHandler = approvalHandler
        self.contextProvider = contextProvider
        self.attachmentResolver = attachmentResolver
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
        self.configuration = configuration
        self.sleep = sleep
    }

    // MARK: - Public API

    /// Sends `text` as the user's next message and streams the reply.
    ///
    /// `attachments` are library items (notes, documents) whose text goes to the model with this
    /// message; the message stores only their references (see `MessageAttachment`).
    ///
    /// The stream never throws: problems end it with `.failed` (configuration and attachment
    /// problems before anything is persisted, provider problems after a failed assistant message
    /// is stored).
    public func send(text: String, attachments: [EntityReference] = [], in conversationID: Conversation.ID) -> AsyncThrowingStream<AssistantUpdate, any Error> {
        let (stream, updates) = AsyncThrowingStream<AssistantUpdate, any Error>.makeStream()
        guard activeTurns[conversationID] == nil else {
            updates.yield(.failed(AssistantError.turnInProgress.presentation))
            updates.finish()
            return stream
        }
        let turnID = UUID()
        let task = Task {
            await self.runTurn(text: text, attachments: attachments, conversationID: conversationID, turnID: turnID, updates: updates)
        }
        updates.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        activeTurns[conversationID] = ActiveTurn(id: turnID, task: task)
        return stream
    }

    /// Stops the reply being generated in `conversationID`, keeping what was received so far.
    public func cancel(conversationID: Conversation.ID) {
        activeTurns[conversationID]?.task.cancel()
    }

    public func isResponding(in conversationID: Conversation.ID) -> Bool {
        activeTurns[conversationID] != nil
    }

    // MARK: - Preparation

    /// Resolves model, provider, key, prompt and tools. Throws before anything is persisted.
    func prepare(conversationID: Conversation.ID, turnID: UUID) async throws -> (TurnSetup, Conversation) {
        guard let conversation = try await database.read({ db in try ConversationRepository.fetch(conversationID, in: db) }) else {
            throw AssistantError.conversationNotFound
        }
        let defaultSelection = await settings.value(AssistantSettings.defaultModel)
        guard let selection = conversation.selection ?? defaultSelection else {
            throw AssistantError.noModelSelected
        }
        guard let provider = providers.provider(selection.providerID) else {
            throw AssistantError.providerUnavailable(selection.providerID)
        }
        guard try hasCredentials(provider) else {
            throw ProviderError.missingAPIKey(provider: provider.displayName)
        }
        let descriptor = await catalog.descriptor(for: selection)
            ?? ModelDescriptor(id: selection.modelID, displayName: selection.modelID, providerID: selection.providerID)

        let memoryEnabled = await memory.isMemoryEnabled()
        let memories = memoryEnabled ? try await memory.memories(includeDisabled: false) : []
        let appContext = await contextProvider?.contextSummary()
        let system = contextBuilder.systemPrompt(
            now: timeSource.now(),
            calendar: calendar,
            memories: memories,
            memoryEnabled: memoryEnabled,
            appContext: appContext
        )

        var available: [String: any AssistantTool] = [:]
        if descriptor.supportsTools {
            for tool in tools.all {
                available[tool.definition.name] = tool
            }
            if memoryEnabled {
                available[RememberTool.name] = RememberTool(store: memory)
                available[ForgetTool.name] = ForgetTool(store: memory)
            }
        }
        let definitions = available.keys.sorted().compactMap { available[$0]?.definition }

        let maxTokens = min(configuration.maxOutputTokens, descriptor.maxOutputTokens ?? configuration.unknownModelMaxOutputTokens)
        let contextWindow = descriptor.contextWindow ?? configuration.unknownModelContextWindow
        let reserve = ContextBuilder.estimatedTokens(for: system)
            + ContextBuilder.estimatedTokens(for: definitions)
            + configuration.contextSafetyMargin
        let setup = TurnSetup(
            conversationID: conversationID,
            turnID: turnID,
            context: ActionContext(actor: .assistant, correlationID: turnID),
            selection: selection,
            provider: provider,
            system: system,
            tools: available,
            toolDefinitions: definitions,
            requiresApproval: await settings.value(AssistantSettings.requireApprovalForMutatingTools),
            maxTokens: max(1, maxTokens),
            historyBudget: ContextBuilder.historyBudget(contextWindow: contextWindow, maxOutputTokens: maxTokens, reserve: reserve)
        )
        return (setup, conversation)
    }
}
