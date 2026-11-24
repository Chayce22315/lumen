import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenIntelligence
import LumenSearch
import LumenApplication

/// A conversation found by searching, with the matched words emphasised.
public struct ConversationSearchRow: Sendable, Hashable, Identifiable {
    public let conversation: Conversation
    public let titleHighlights: [HighlightRange]
    /// An excerpt of the best-matching message.
    public let snippet: Snippet?

    public var id: Conversation.ID { conversation.id }
}

/// The list of conversations.
@MainActor
@Observable
public final class ConversationsViewModel {
    public private(set) var state: LoadState<[Conversation]> = .idle
    public var showsArchived = false {
        didSet { Task { await load() } }
    }
    /// Text in the search field. Results follow it after a short pause.
    public var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    /// Search results; `nil` while the search field is empty.
    public private(set) var searchResults: [ConversationSearchRow]?
    /// Saved prompts offered by plugins; each starts a conversation with the prompt to send.
    public private(set) var shortcuts: [PromptShortcut] = []

    private let services: LumenServices
    private let debounce: TimeInterval
    private let observation = ObservationHandle()
    private let pendingSearch = ObservationHandle()
    private let pluginObservation = ObservationHandle()

    public init(services: LumenServices, debounce: TimeInterval = 0.2) {
        self.services = services
        self.debounce = debounce
    }

    public var isSearching: Bool { searchQuery.nonBlank != nil }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["intelligence", "sync"], entityKinds: [.conversation, .chatMessage]), into: observation) { [weak self] in
            guard let self else { return }
            await self.load()
            if self.isSearching { await self.search() }
        }
        services.events.observe(EventFilter(modules: ["plugins"]), into: pluginObservation) { [weak self] in
            guard let self else { return }
            self.shortcuts = self.services.plugins.promptShortcuts()
        }
    }

    /// Runs the current query now: titles and message text, every term matched as a prefix.
    public func search() async {
        let query = searchQuery
        guard query.nonBlank != nil else {
            searchResults = nil
            return
        }
        do {
            let hits = try await services.intelligence.conversations.search(query)
            guard query == searchQuery else { return } // a newer query is on its way
            let tokens = FTSQueryBuilder.tokens(for: query)
            searchResults = hits.map { hit in
                ConversationSearchRow(
                    conversation: hit.conversation,
                    titleHighlights: SnippetBuilder.highlights(in: hit.conversation.displayTitle, tokens: tokens),
                    snippet: hit.matchedText.flatMap { SnippetBuilder.snippet(for: $0, tokens: tokens) }
                )
            }
        } catch {
            services.errors.report(error, context: "Searching conversations")
        }
    }

    private func scheduleSearch() {
        guard isSearching else {
            pendingSearch.replace(with: Task {})
            searchResults = nil
            return
        }
        let delay = UInt64(max(0, debounce) * 1_000_000_000)
        pendingSearch.replace(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay) // cancellation (a newer keystroke) ends the wait early
            guard !Task.isCancelled else { return }
            await self?.search()
        })
    }

    public func load() async {
        shortcuts = services.plugins.promptShortcuts()
        do {
            state = .loaded(try await services.intelligence.conversations.list(includeArchived: showsArchived))
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public func create() async -> Conversation? {
        do {
            return try await services.intelligence.conversations.create()
        } catch {
            services.errors.report(error, context: "Starting a conversation")
            return nil
        }
    }

    public func rename(_ id: Conversation.ID, to title: String) async {
        await perform("Renaming a conversation") { _ = try await $0.rename(id, to: title) }
    }

    public func setArchived(_ archived: Bool, for id: Conversation.ID) async {
        await perform("Archiving a conversation") { _ = try await $0.setArchived(archived, for: id) }
    }

    public func setPinned(_ pinned: Bool, for id: Conversation.ID) async {
        await perform("Pinning a conversation") { _ = try await $0.setPinned(pinned, for: id) }
    }

    public func delete(_ id: Conversation.ID) async {
        await perform("Deleting a conversation") { try await $0.delete(id) }
    }

    private func perform(_ context: String, _ work: (ConversationService) async throws -> Void) async {
        do {
            try await work(services.intelligence.conversations)
            await load()
        } catch {
            services.errors.report(error, context: context)
        }
    }
}

/// One conversation: history, the reply streaming in, tool activity and approval prompts.
@MainActor
@Observable
public final class ChatViewModel {
    public let conversationID: Conversation.ID
    public private(set) var messages: [ChatMessage] = []
    /// Text of the reply as it streams in; `nil` when not responding.
    public private(set) var streamingText: String?
    /// The tool currently running, for "Searching your notes…" style status.
    public private(set) var activeTool: String?
    public private(set) var failure: ErrorPresentation?
    /// An action waiting for the user's permission.
    public private(set) var pendingApproval: ApprovalRequest?
    public private(set) var isConfigured = true
    public var draft = ""
    /// The conversation, for its model override.
    public private(set) var conversation: Conversation?
    /// The models this device can answer with (configured providers only).
    public private(set) var modelChoices = ModelChoices()
    /// The model chosen in Settings, used when the conversation has no override.
    public private(set) var defaultSelection: ModelSelection?
    /// Library items attached to the next message.
    public private(set) var attachments: [AttachmentCandidate] = []

    /// Matches `AssistantEngine.Configuration.maxAttachmentsPerMessage`.
    public static let maximumAttachments = 10

    private let services: LumenServices
    private let reply = ObservationHandle()
    private let approvals = ObservationHandle()

    /// - Parameter initialDraft: text placed in the composer (a plugin's prompt shortcut); the
    ///   user reads and sends it.
    public init(conversationID: Conversation.ID, services: LumenServices, initialDraft: String = "") {
        self.conversationID = conversationID
        self.services = services
        self.draft = initialDraft
    }

    public var isResponding: Bool { streamingText != nil }
    public var canSend: Bool { !isResponding && draft.collapsingWhitespace.nonBlank != nil }

    public func start() async {
        isConfigured = await services.isAssistantConfigured()
        await reload()
        let stream = await services.intelligence.approvals.requests()
        approvals.replace(with: Task { @MainActor [weak self] in
            for await request in stream {
                self?.pendingApproval = request
            }
        })
        await loadConversation()
        await loadModels()
    }

    // MARK: - Model

    /// The model answering in this conversation: its override, else the default.
    public var activeSelection: ModelSelection? { conversation?.selection ?? defaultSelection }

    /// Whether the conversation follows the Settings default.
    public var followsDefaultModel: Bool { conversation?.selection == nil }

    /// Display name of the active model.
    public var activeModelName: String? { activeSelection.map(displayName(for:)) }

    /// Display name of the default model, for the "Default" option.
    public var defaultModelName: String? { defaultSelection.map(displayName(for:)) }

    /// The picker is offered only when at least one model can actually answer.
    public var canChooseModel: Bool { !modelChoices.isEmpty }

    public func displayName(for selection: ModelSelection) -> String {
        modelChoices.descriptor(for: selection)?.displayName ?? selection.modelID
    }

    public func loadModels(refresh: Bool = false) async {
        defaultSelection = await services.settings.value(AssistantSettings.defaultModel)
        modelChoices = await services.intelligence.assistant.modelChoices(refresh: refresh)
    }

    /// Sets this conversation's model; `nil` returns it to the Settings default. Only models
    /// offered in `modelChoices` are accepted.
    public func chooseModel(_ selection: ModelSelection?) async {
        if let selection, !modelChoices.contains(selection) { return }
        do {
            conversation = try await services.intelligence.conversations.setSelection(selection, for: conversationID)
        } catch {
            services.errors.report(error, context: "Choosing a model")
        }
    }

    private func loadConversation() async {
        do {
            conversation = try await services.intelligence.conversations.conversation(conversationID)
        } catch {
            services.errors.report(error, context: "Loading the conversation")
        }
    }

    // MARK: - Attachments

    public var canAttachMore: Bool { attachments.count < Self.maximumAttachments }

    public func attach(_ candidate: AttachmentCandidate) {
        guard canAttachMore, !attachments.contains(where: { $0.reference == candidate.reference }) else { return }
        attachments.append(candidate)
    }

    public func removeAttachment(_ reference: EntityReference) {
        attachments.removeAll { $0.reference == reference }
    }

    public func reload() async {
        do {
            messages = try await services.intelligence.conversations.messages(in: conversationID)
        } catch {
            services.errors.report(error, context: "Loading the conversation")
        }
    }

    /// Sends the draft with its attachments. When the turn fails before the message was stored
    /// (an attachment was deleted meanwhile, no model is set up), the draft and attachments are
    /// put back so nothing the user typed is lost.
    public func send() async {
        guard canSend else { return }
        let text = draft
        let attached = attachments
        let storedBefore = messages.count
        draft = ""
        attachments = []
        failure = nil
        streamingText = ""
        defer {
            if failure != nil, messages.count == storedBefore {
                if draft.isEmpty { draft = text }
                if attachments.isEmpty { attachments = attached }
            }
        }
        let stream = await services.intelligence.assistant.send(text: text, attachments: attached.map(\.reference), in: conversationID)
        await reload()
        let finished = Task { @MainActor [weak self] in
            do {
                for try await update in stream {
                    guard let self else { return }
                    switch update {
                    case .messageStarted:
                        self.streamingText = ""
                    case .textDelta(let delta):
                        self.streamingText = (self.streamingText ?? "") + delta
                    case .toolStarted(let name):
                        self.activeTool = name
                    case .toolFinished:
                        self.activeTool = nil
                        self.streamingText = ""
                        await self.reload()
                    case .completed:
                        await self.reload()
                    case .failed(let presentation):
                        self.failure = presentation
                    }
                }
            } catch {
                self?.failure = ErrorPresentation.from(error)
            }
            self?.streamingText = nil
            self?.activeTool = nil
            await self?.reload()
        }
        reply.replace(with: finished)
        await finished.value
    }

    /// Stops the reply; the partial answer is kept.
    public func cancel() async {
        await services.intelligence.assistant.cancel(conversationID: conversationID)
    }

    public func answerApproval(_ approved: Bool) async {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        await services.intelligence.approvals.resolve(request.id, approved: approved)
    }
}
