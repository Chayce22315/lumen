import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenIntelligence
import LumenSearch

/// Conversations with the assistant.
struct AssistantView: View {
    let services: LumenServices
    let model: AppModel
    /// The conversation shown beside the list on iPad; `nil` where rows push onto a stack.
    let selection: Binding<AppDestination?>?
    @State private var conversations: ConversationsViewModel
    @State private var isConfigured = true
    @FocusState private var searchFocused: Bool
    @State private var shortcutLaunch: ShortcutLaunch?

    /// A conversation started from a plugin's prompt shortcut, opened with the prompt in the composer.
    struct ShortcutLaunch: Hashable {
        let conversationID: Conversation.ID
        let prompt: String
    }

    init(services: LumenServices, model: AppModel, selection: Binding<AppDestination?>? = nil) {
        self.services = services
        self.model = model
        self.selection = selection
        _conversations = State(initialValue: ConversationsViewModel(services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Assistant")
            .searchable(text: $conversations.searchQuery, prompt: "Search conversations")
            .searchFocused($searchFocused)
            .onChange(of: model.router.searchFocusRequest, initial: true) {
                // ⌘F
                if model.router.claimSearchFocus(in: .assistant) { searchFocused = true }
            }
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
            .navigationDestination(item: $shortcutLaunch) { launch in
                ChatView(conversationID: launch.conversationID, services: services, model: model, initialDraft: launch.prompt)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let results = conversations.searchResults {
            // Searching past conversations works without a configured model.
            searchResults(results)
        } else if !isConfigured {
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
            case .loaded(let list) where list.isEmpty && conversations.shortcuts.isEmpty:
                StateMessage("Ask anything", message: "Plan your day, find a note, or have Lumen create tasks for you.", symbolName: "bubble.left.and.text.bubble.right", actionTitle: "Start a conversation") {
                    Task { await startConversation() }
                }
            case .loaded(let list):
                SelectableList(selection: selection) {
                    if !conversations.shortcuts.isEmpty {
                        Section("Shortcuts") {
                            ForEach(conversations.shortcuts) { shortcut in
                                Button { Task { await start(shortcut) } } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortcut.title).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
                                        Text(shortcut.prompt).lumenText(.caption).foregroundStyle(LumenColor.textSecondary).lineLimit(2)
                                        Text(shortcut.pluginName).lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
                                    }
                                }
                                .accessibilityHint("Starts a conversation with this prompt ready to send")
                                .listRowBackground(LumenColor.surface)
                            }
                        }
                    }
                    Section {
                        ForEach(list) { conversation in
                            let destination = AppDestination.entity(conversation.reference)
                            NavigationLink(value: destination) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: LumenSpace.xs) {
                                        if conversation.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(LumenColor.accent) }
                                        Text(conversation.title.isEmpty ? "New conversation" : conversation.title).lumenText(.body).lineLimit(1)
                                    }
                                    Text(conversation.updatedAt, style: .relative).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                                }
                            }
                            .selectableRow(destination, selection: selection, background: LumenColor.surface)
                            .swipeActions {
                                Button(role: .destructive) {
                                    // The detail beside the list would show a deleted conversation.
                                    if selection?.wrappedValue == destination { selection?.wrappedValue = nil }
                                    Task { await conversations.delete(conversation.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { Task { await conversations.setPinned(!conversation.isPinned, for: conversation.id) } } label: { Label("Pin", systemImage: "pin") }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ results: [ConversationSearchRow]) -> some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: conversations.searchQuery)
        } else {
            SelectableList(selection: selection) {
                ForEach(results) { row in
                    let destination = AppDestination.entity(row.conversation.reference)
                    NavigationLink(value: destination) {
                        VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                            HighlightedText(text: row.conversation.displayTitle, highlights: row.titleHighlights)
                                .lineLimit(1)
                            if let snippet = row.snippet {
                                HighlightedText(text: snippet.text, highlights: snippet.highlights, role: .footnote, color: LumenColor.textSecondary)
                                    .lineLimit(2)
                            }
                            if row.conversation.isArchived {
                                Text("Archived").lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
                            }
                        }
                    }
                    .selectableRow(destination, selection: selection, background: LumenColor.surface)
                }
            }
        }
    }

    /// Starts a conversation with a plugin's prompt in the composer; the user reads and sends it.
    private func start(_ shortcut: PromptShortcut) async {
        if let conversation = await conversations.create() {
            shortcutLaunch = ShortcutLaunch(conversationID: conversation.id, prompt: shortcut.prompt)
        }
    }

    private func startConversation() async {
        if let conversation = await conversations.create() {
            // Beside the list the new conversation becomes the selection; on a stack it is pushed.
            if let selection {
                selection.wrappedValue = .entity(conversation.reference)
            } else {
                model.router.push(.entity(conversation.reference))
            }
        }
    }
}

/// One conversation: messages, the streaming reply and the composer.
struct ChatView: View {
    let services: LumenServices
    let model: AppModel
    @State private var chat: ChatViewModel
    @State private var isPickingAttachments = false
    @FocusState private var composerFocused: Bool

    init(conversationID: Conversation.ID, services: LumenServices, model: AppModel, initialDraft: String = "") {
        self.services = services
        self.model = model
        _chat = State(initialValue: ChatViewModel(conversationID: conversationID, services: services, initialDraft: initialDraft))
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
        .toolbar {
            if chat.canChooseModel {
                ToolbarItem(placement: .topBarTrailing) { modelMenu }
            }
        }
        .task { await chat.start() }
        .sheet(isPresented: $isPickingAttachments) {
            NavigationStack {
                AttachmentPickerView(services: services, alreadyAttached: Set(chat.attachments.map(\.reference))) { candidate in
                    chat.attach(candidate)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { chat.pendingApproval }, set: { if $0 == nil { Task { await chat.answerApproval(false) } } })) { request in
            ApprovalSheet(request: request) { approved in
                Task { await chat.answerApproval(approved) }
            }
            .presentationDetents([.height(240)])
        }
    }

    /// Picks this conversation's model among those that can answer; "Default" follows Settings.
    private var modelMenu: some View {
        Menu {
            Button {
                Task { await chat.chooseModel(nil) }
            } label: {
                let title = chat.defaultModelName.map { "Default (\($0))" } ?? "Default"
                if chat.followsDefaultModel {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
            ForEach(chat.modelChoices.providers) { provider in
                Section(provider.displayName) {
                    ForEach(provider.models) { descriptor in
                        Button {
                            Task { await chat.chooseModel(descriptor.selection) }
                        } label: {
                            if !chat.followsDefaultModel && chat.activeSelection == descriptor.selection {
                                Label(descriptor.displayName, systemImage: "checkmark")
                            } else {
                                Text(descriptor.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: LumenSpace.xxs) {
                Text(chat.activeModelName ?? "Model").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .lumenText(.footnote)
        }
        .accessibilityLabel("Model")
        .accessibilityValue(chat.activeModelName ?? "Not chosen")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LumenSpace.s) {
                        ForEach(chat.attachments) { candidate in
                            AttachmentChip(candidate: candidate) { chat.removeAttachment(candidate.reference) }
                        }
                    }
                }
            }
            composerRow
        }
        .padding(.horizontal, LumenSpace.screen)
        .padding(.vertical, LumenSpace.s)
        .background(.bar)
        .animation(.lumenSnappy, value: chat.attachments.map(\.reference))
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: LumenSpace.s) {
            Button { isPickingAttachments = true } label: {
                Image(systemName: "paperclip").font(.system(size: 20))
                    .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
            }
            .disabled(!chat.isConfigured || !chat.canAttachMore || chat.isResponding)
            .accessibilityLabel("Attach from library")
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
    }
}

/// A library item attached to the message being written, removable before sending.
private struct AttachmentChip: View {
    let candidate: AttachmentCandidate
    let remove: () -> Void

    var body: some View {
        HStack(spacing: LumenSpace.xs) {
            Image(systemName: candidate.symbolName)
            Text(candidate.title).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(LumenColor.textSecondary)
            .accessibilityLabel("Remove \(candidate.title)")
        }
        .lumenText(.caption)
        .foregroundStyle(LumenColor.textPrimary)
        .padding(.horizontal, LumenSpace.s)
        .padding(.vertical, LumenSpace.xs)
        .background(LumenColor.accentSubtle, in: Capsule())
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: LumenSpace.xxl) }
            VStack(alignment: .leading, spacing: LumenSpace.xs) {
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    Label(Self.describe(attachment), systemImage: "paperclip")
                        .lumenText(.caption)
                        .foregroundStyle(isUser ? LumenColor.onAccent : LumenColor.textSecondary)
                }
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
        .accessibilityLabel(accessibilityText(isUser: isUser))
    }

    private func accessibilityText(isUser: Bool) -> String {
        var text = isUser ? "You: \(message.text)" : "Assistant: \(message.text)"
        if !message.attachments.isEmpty {
            text += ". Attached: " + message.attachments.map(\.title).joined(separator: ", ")
        }
        return text
    }

    /// "Trip notes", or "Trip notes · first 12,000 characters" when only the start was sent.
    static func describe(_ attachment: MessageAttachment) -> String {
        guard attachment.isTruncated else { return attachment.title }
        return "\(attachment.title) · first \(attachment.includedCharacters.formatted()) characters"
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
