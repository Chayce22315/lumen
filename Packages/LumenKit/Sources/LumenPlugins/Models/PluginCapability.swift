import Foundation

/// A permission a plugin must hold to use part of Lumen. The user grants capabilities explicitly;
/// the `PluginContext` enforces them on every access.
///
/// Raw values are persisted in grants and written in plugin packages, so they never change once
/// shipped.
public enum PluginCapability: String, Sendable, Codable, Hashable, CaseIterable, Comparable, Identifiable {
    case readTasks
    case writeTasks
    case readNotes
    case writeNotes
    case readCalendar
    case writeCalendar
    case searchContent
    case contributeCommands
    case contributeSearchResults
    case contributeAssistantTools
    case contributeAutomationActions
    case contributeDashboardWidgets
    case contributeWorkflowTemplates
    case contributeAssistantPrompts
    case sendNotifications
    case network

    public enum Risk: Int, Sendable, Comparable {
        case low, medium, high
        public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { rawValue }

    public static func < (lhs: PluginCapability, rhs: PluginCapability) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What a third-party plugin package may ask for. Packages are data that Lumen's own engines
    /// execute, so only capabilities a package's contributions can actually use are allowed;
    /// asking for anything else is refused before installation.
    public static let packageCapabilities: Set<PluginCapability> = [
        .contributeCommands, .contributeWorkflowTemplates, .contributeAssistantPrompts, .contributeAutomationActions, .network,
    ]

    public var title: String {
        switch self {
        case .readTasks: return "Read tasks and projects"
        case .writeTasks: return "Create and change tasks"
        case .readNotes: return "Read notes and documents"
        case .writeNotes: return "Create and change notes"
        case .readCalendar: return "Read calendar events"
        case .writeCalendar: return "Create and change events"
        case .searchContent: return "Search your content"
        case .contributeCommands: return "Add commands"
        case .contributeSearchResults: return "Add search results"
        case .contributeAssistantTools: return "Give the assistant new tools"
        case .contributeAutomationActions: return "Add automation actions"
        case .contributeDashboardWidgets: return "Add dashboard widgets"
        case .contributeWorkflowTemplates: return "Offer automation templates"
        case .contributeAssistantPrompts: return "Add assistant shortcuts"
        case .sendNotifications: return "Send notifications"
        case .network: return "Connect to the internet"
        }
    }

    /// What granting the capability allows, in plain language, for the install review.
    public var explanation: String {
        switch self {
        case .readTasks: return "Can see your tasks and projects."
        case .writeTasks: return "Can create, change and complete your tasks."
        case .readNotes: return "Can see your notes and documents."
        case .writeNotes: return "Can create and change your notes."
        case .readCalendar: return "Can see your calendar events."
        case .writeCalendar: return "Can create and change calendar events."
        case .searchContent: return "Can search everything in Lumen."
        case .contributeCommands: return "Adds commands to the command palette. They open places in Lumen or run this plugin's automations."
        case .contributeSearchResults: return "Adds results to search."
        case .contributeAssistantTools: return "Lets the assistant use new tools."
        case .contributeAutomationActions: return "Adds steps your automations can use."
        case .contributeDashboardWidgets: return "Adds cards to Home."
        case .contributeWorkflowTemplates: return "Offers ready-made automations. Nothing runs until you add one in Automations."
        case .contributeAssistantPrompts: return "Adds saved prompts to the assistant. You see each prompt before it is sent."
        case .sendNotifications: return "Can show notifications."
        case .network: return "Its automation steps can send the data you give them to the internet addresses listed. Only the addresses you allow are ever contacted."
        }
    }

    /// Data-modifying and data-exfiltrating capabilities are high risk and shown prominently.
    public var risk: Risk {
        switch self {
        case .writeTasks, .writeNotes, .writeCalendar, .network, .contributeAssistantTools: return .high
        case .readTasks, .readNotes, .readCalendar, .searchContent, .sendNotifications: return .medium
        case .contributeCommands, .contributeSearchResults, .contributeAutomationActions, .contributeDashboardWidgets,
             .contributeWorkflowTemplates, .contributeAssistantPrompts: return .low
        }
    }
}
