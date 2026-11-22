import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenIntelligence

/// Conversations with the assistant.
struct AssistantView: View {
    let services: LumenServices
    let model: AppModel
    @State private var conversations: ConversationsViewModel
    @State private var isConfigured = true

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _conversations = State(initialValue: ConversationsViewModel(services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Assistant")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await startConversation() } } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation")
                }
            }
            .task {
                isConfigured = await services.isAssistantConfigured()
                await conversations.start()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isConfigured {
            StateMessage(
                "Set up the assistant",
                message: "Add an API key for Anthropic or OpenAI and choose a model. Keys are stored in the Keychain on this device.",
                symbolName: "sparkles",
                actionTitle: "Open assistant settings"
            ) {
                model.router.open(.settings(.assistant))
            }
        } else {
            switch conversations.state {
            case .idle, .loading:
                SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
            case .failed(let error):
                StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
            case .loaded(let list) where list.isEmpty:
                StateMessage("Ask anything", message: "Plan your day, find a note, or have Lumen create tasks for you.", symbolName: "bubble.left.and.text.bubble.right", actionTitle: "Start a conversation") {
                    Task { await startConversation() }
                }
            case .loaded(let list):
                List(list) { conversation in
                    NavigationLink(value: AppDestination.entity(conversation.reference)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: LumenSpace.xs) {
                                if conversation.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(LumenColor.accent) }
                                Text(conversation.title.isEmpty ? "New conversation" : conversation.title).lumenText(.body).lineLimit(1)
                            }
                            Text(conversation.updatedAt, style: .relative).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                        }
                    }
                    .listRowBackground(LumenColor.surface)
                    .swipeActions {
                        Button(role: .destructive) { Task { await conversations.delete(conversation.id) } } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await conversations.setPinned(!conversation.isPinned, for: conversation.id) } } label: { Label("Pin", systemImage: "pin") }
                    }
                }
            }
        }
    }

    private func startConversation() async {
        if let conversation = await conversations.create() {
            model.router.push(.entity(conversation.reference))
        }
    }
}

/// One conversation: messages, the streaming reply and the composer.
struct ChatView: View {
    let services: LumenServices
    let model: AppModel
    @State private var chat: ChatViewModel
    @FocusState private var composerFocused: Bool

    init(conversationID: Conversation.ID, services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _chat = State(initialValue: ChatViewModel(conversationID: conversationID, services: services))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LumenSpace.l) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if let streaming = chat.streamingText {
                        StreamingBubble(text: streaming, tool: chat.activeTool).id("streaming")
                    }
                    if let failure = chat.failure {
                        Banner(title: failure.title, message: failure.message) {}
                            .id("failure")
                    }
                }
                .padding(LumenSpace.screen)
            }
            .onChange(of: chat.streamingText) { _, _ in
                withAnimation(.lumenSmooth) { proxy.scrollTo("streaming", anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let last = chat.messages.last { withAnimation(.lumenSmooth) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .lumenScreenBackground()
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await chat.start() }
        .sheet(item: Binding(get: { chat.pendingApproval }, set: { if $0 == nil { Task { await chat.answerApproval(false) } } })) { request in
            ApprovalSheet(request: request) { approved in
                Task { await chat.answerApproval(approved) }
            }
            .presentationDetents([.height(240)])
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: LumenSpace.s) {
            TextField(chat.isConfigured ? "Message" : "Set up a model in Settings first", text: $chat.draft, axis: .vertical)
                .lumenText(.body)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, LumenSpace.m)
                .padding(.vertical, LumenSpace.s + 2)
                .background(LumenColor.surface, in: RoundedRectangle(cornerRadius: LumenRadius.large, style: .continuous))
                .disabled(!chat.isConfigured)
            if chat.isResponding {
                Button { Task { await chat.cancel() } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30))
                }
                .accessibilityLabel("Stop")
            } else {
                Button { Task { await chat.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(!chat.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, LumenSpace.screen)
        .padding(.vertical, LumenSpace.s)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: LumenSpace.xxl) }
            VStack(alignment: .leading, spacing: LumenSpace.xs) {
                if !message.text.isEmpty {
                    Text(attributed(message.text))
                        .lumenText(.body)
                        .foregroundStyle(isUser ? LumenColor.onAccent : LumenColor.textPrimary)
                        .textSelection(.enabled)
                }
                if !message.toolUses.isEmpty {
                    ForEach(Array(message.toolUses.map { $0.name }.enumerated()), id: \.offset) { _, name in
                        Label(name.replacingOccurrences(of: "_", with: " "), systemImage: "wrench.and.screwdriver")
                            .lumenText(.caption)
                            .foregroundStyle(isUser ? LumenColor.onAccent : LumenColor.textSecondary)
                    }
                }
                if message.status == .cancelled {
                    Text("Stopped").lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
                }
            }
            .padding(.horizontal, LumenSpace.m)
            .padding(.vertical, LumenSpace.s + 2)
            .background(isUser ? LumenColor.accentFill : LumenColor.surface, in: RoundedRectangle(cornerRadius: LumenRadius.large, style: .continuous))
            if !isUser { Spacer(minLength: LumenSpace.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You: \(message.text)" : "Assistant: \(message.text)")
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct StreamingBubble: View {
    let text: String
    let tool: String?
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.xs) {
            if let tool {
                Label(ToolStatus.describe(tool), systemImage: "sparkles")
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.accentText)
                    .symbolEffect(.pulse, options: .repeating)
            }
            if text.isEmpty && tool == nil {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().frame(width: 6, height: 6)
                            .opacity(pulse ? 1 : 0.3)
                            .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: pulse)
                    }
                }
                .foregroundStyle(LumenColor.textTertiary)
                .onAppear { pulse = true }
                .accessibilityLabel("Thinking")
            } else if !text.isEmpty {
                Text(text).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
            }
        }
        .padding(.horizontal, LumenSpace.m)
        .padding(.vertical, LumenSpace.s + 2)
        .background(LumenColor.surface, in: RoundedRectangle(cornerRadius: LumenRadius.large, style: .continuous))
    }
}

enum ToolStatus {
    static func describe(_ tool: String) -> String {
        switch tool {
        case "search_lumen": return "Searching your Lumen…"
        case "list_tasks": return "Looking at your tasks…"
        case "create_task": return "Creating a task…"
        case "complete_task": return "Completing a task…"
        case "get_agenda": return "Checking your calendar…"
        case "create_note": return "Writing a note…"
        case "read_note": return "Reading a note…"
        case "remember": return "Saving a memory…"
        case "run_workflow": return "Running an automation…"
        default: return "Working…"
        }
    }
}

/// Asks before the assistant changes the user's data.
private struct ApprovalSheet: View {
    let request: ApprovalRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: LumenSpace.l) {
            Image(systemName: "hand.raised").font(.title2).foregroundStyle(LumenColor.accent)
            Text("Allow the assistant to:").lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary)
            Text(request.summary).lumenText(.headline).multilineTextAlignment(.center)
            HStack(spacing: LumenSpace.m) {
                Button("Don't allow") { answer(false) }.buttonStyle(.lumenSecondary)
                Button("Allow") { answer(true) }.buttonStyle(.lumenPrimary)
            }
        }
        .padding(LumenSpace.screen)
    }
}
