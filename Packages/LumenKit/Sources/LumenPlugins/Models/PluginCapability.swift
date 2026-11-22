import Foundation

/// A permission a plugin must hold to use part of Lumen. The user grants capabilities explicitly;
/// the `PluginContext` enforces them on every access.
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
    case sendNotifications
    case network

    public enum Risk: Int, Sendable, Comparable {
        case low, medium, high
        public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { rawValue }

    public static func < (lhs: PluginCapability, rhs: PluginCapability) -> Bool { lhs.rawValue < rhs.rawValue }

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
        case .sendNotifications: return "Send notifications"
        case .network: return "Connect to the internet"
        }
    }

    /// Data-modifying and data-exfiltrating capabilities are high risk and shown prominently.
    public var risk: Risk {
        switch self {
        case .writeTasks, .writeNotes, .writeCalendar, .network, .contributeAssistantTools: return .high
        case .readTasks, .readNotes, .readCalendar, .searchContent, .sendNotifications: return .medium
        case .contributeCommands, .contributeSearchResults, .contributeAutomationActions, .contributeDashboardWidgets: return .low
        }
    }
}
