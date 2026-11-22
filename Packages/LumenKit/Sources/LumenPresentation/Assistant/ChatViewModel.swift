import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenIntelligence
import LumenApplication

/// The list of conversations.
@MainActor
@Observable
public final class ConversationsViewModel {
    public private(set) var state: LoadState<[Conversation]> = .idle
    public var showsArchived = false {
        didSet { Task { await load() } }
    }

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["intelligence", "sync"], entityKinds: [.conversation, .chatMessage]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
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

    private let services: LumenServices
    private let reply = ObservationHandle()
    private let approvals = ObservationHandle()

    public init(conversationID: Conversation.ID, services: LumenServices) {
        self.conversationID = conversationID
        self.services = services
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
    }

    public func reload() async {
        do {
            messages = try await services.intelligence.conversations.messages(in: conversationID)
        } catch {
            services.errors.report(error, context: "Loading the conversation")
        }
    }

    public func send() async {
        guard canSend else { return }
        let text = draft
        draft = ""
        failure = nil
        streamingText = ""
        let stream = await services.intelligence.assistant.send(text: text, in: conversationID)
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
