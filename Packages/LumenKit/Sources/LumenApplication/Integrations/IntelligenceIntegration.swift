import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenOrganization
import LumenIntelligence
import LumenAutomation
import LumenPlugins
import LumenSearch
import LumenSync

/// The short workspace summary added to the assistant's system prompt.
struct WorkspaceContextProvider: AssistantContextProvider {
    let agenda: AgendaService
    let projects: ProjectService

    func contextSummary() async -> String? {
        guard let overview = try? await agenda.todayOverview(focusLimit: 5) else { return nil }
        var lines = ["Tasks: \(overview.summary.dueToday) due today, \(overview.summary.overdue) overdue, \(overview.summary.completedToday) completed today, \(overview.summary.open) open in total."]
        if let next = overview.nextEvent {
            lines.append("Next event: \(next.title) at \(ISO8601DateFormatter().string(from: next.start)).")
        }
        if !overview.focusTasks.isEmpty {
            lines.append("Today's focus: " + overview.focusTasks.map { "\($0.title) [\($0.reference.uri)]" }.joined(separator: "; ") + ".")
        }
        if let live = try? await projects.projects(statuses: [.active]), !live.isEmpty {
            lines.append("Active projects: " + live.prefix(8).map(\.name).joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}

enum IntelligenceIntegration {
    static func syncHandlers() -> [any SyncEntityHandler] {
        [
            CodableSyncHandler<Conversation>(
                kind: .conversation,
                fetch: { id, db in try ConversationRepository.fetch(Conversation.ID(id), in: db) },
                upsert: { conversation, db in try ConversationRepository.upsertRow(conversation, in: db) },
                delete: { id, db in try ConversationRepository.deleteRow(Conversation.ID(id), in: db) }
            ),
            CodableSyncHandler<ChatMessage>(
                kind: .chatMessage,
                fetch: { id, db in try MessageRepository.fetch(ChatMessage.ID(id), in: db) },
                upsert: { message, db in try MessageRepository.upsertRow(message, in: db) },
                delete: { id, db in try MessageRepository.deleteRow(ChatMessage.ID(id), in: db) }
            ),
            CodableSyncHandler<MemoryItem>(
                kind: .memory,
                fetch: { id, db in try MemoryRepository.fetch(MemoryItem.ID(id), in: db) },
                upsert: { memory, db in try MemoryRepository.upsertRow(memory, in: db) },
                delete: { id, db in try MemoryRepository.deleteRow(MemoryItem.ID(id), in: db) }
            ),
            CodableSyncHandler<Workflow>(
                kind: .workflow,
                fetch: { id, db in try WorkflowRepository.fetch(Workflow.ID(id), in: db) },
                upsert: { workflow, db in try WorkflowRepository.upsertRow(workflow, in: db) },
                delete: { id, db in _ = try WorkflowRepository.deleteRow(Workflow.ID(id), in: db) }
            ),
        ]
    }

    /// Whether the assistant can answer: a default model is chosen and its provider has the
    /// credentials it needs.
    static func isConfigured(settings: SettingsStore, providers: ProviderRegistry, secrets: any SecretStore) async -> Bool {
        guard let selection = await settings.value(AssistantSettings.defaultModel),
              let provider = providers.provider(selection.providerID) else { return false }
        guard provider.requiresAPIKey else { return true }
        do {
            return try secrets.secret(for: selection.providerID.apiKeySecret)?.nonBlank != nil
        } catch {
            return false
        }
    }
}

struct WorkflowSearchSource: SearchableSource {
    let automation: AutomationEngine

    var kind: EntityKind { .workflow }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await automation.workflow(Workflow.ID(id)).map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await automation.workflows().map(Self.document(for:))
    }

    static func document(for workflow: Workflow) -> SearchDocument {
        SearchDocument(
            reference: EntityReference(kind: .workflow, id: workflow.id),
            title: workflow.name,
            subtitle: "Automation\(workflow.isEnabled ? "" : " · Off")",
            body: workflow.summary,
            updatedAt: workflow.updatedAt,
            boost: 0.9
        )
    }
}

struct ConversationSearchSource: SearchableSource {
    let conversations: ConversationService

    var kind: EntityKind { .conversation }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await conversations.list(includeArchived: true).first { $0.id.rawValue == id }.map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await conversations.list(includeArchived: true).map(Self.document(for:))
    }

    static func document(for conversation: Conversation) -> SearchDocument {
        SearchDocument(
            reference: EntityReference(kind: .conversation, id: conversation.id),
            title: conversation.title,
            subtitle: "Conversation",
            updatedAt: conversation.updatedAt,
            boost: conversation.isArchived ? 0.5 : 0.8
        )
    }
}

/// The assistant: tools over every built-in engine.
struct IntelligenceFeature: LumenPlugin {
    let tools: [any AssistantTool]
    let conversations: ConversationService

    let manifest = PluginManifest(
        id: "app.lumen.intelligence",
        name: "Assistant",
        summary: "The AI assistant and its tools.",
        author: "Lumen",
        version: builtInVersion,
        capabilities: [.contributeAssistantTools, .contributeSearchResults, .contributeCommands]
    )

    func activate(_ context: PluginContext) async throws {
        for tool in tools {
            try context.contribute(tool, to: LumenExtensionPoints.assistantTools)
        }
        try context.contribute(ConversationSearchSource(conversations: conversations), to: LumenExtensionPoints.searchSources)
        try context.contribute(
            LumenCommand(PaletteCommand(id: "assistant.new", title: "New conversation", symbolName: "plus.bubble", keywords: ["chat", "ask", "ai"], category: "Assistant"), action: .navigate(.create(.conversation))),
            to: LumenExtensionPoints.commands
        )
    }
}

/// Automations: actions, triggers and search.
struct AutomationFeature: LumenPlugin {
    let actions: [any AutomationAction]
    let automation: AutomationEngine

    let manifest = PluginManifest(
        id: "app.lumen.automation",
        name: "Automations",
        summary: "Workflows that react to events and schedules.",
        author: "Lumen",
        version: builtInVersion,
        capabilities: [.contributeAutomationActions, .contributeSearchResults]
    )

    func activate(_ context: PluginContext) async throws {
        for action in actions {
            try context.contribute(action, to: LumenExtensionPoints.automationActions)
        }
        try context.contribute(WorkflowSearchSource(automation: automation), to: LumenExtensionPoints.searchSources)
    }
}
