import Foundation
import LumenFoundation

/// Every place the interface can navigate to. Commands, deep links, notifications, widgets and
/// suggestions all resolve to a destination, so navigation has one source of truth.
public enum AppDestination: Sendable, Hashable {
    case home
    case tasks(TaskListKind)
    case calendar
    case library
    case assistant
    case automations
    case insights
    case notifications
    case settings(SettingsSection)
    case search(query: String?)
    /// A specific entity (task, project, note, event, workflow, conversation…).
    case entity(EntityReference)
    /// Opens quick capture, optionally prefilled.
    case capture(text: String?)
    /// Opens the editor for a new item.
    case create(CreationKind)

    public enum CreationKind: String, Sendable, Hashable, CaseIterable {
        case task, project, event, note, workflow, conversation
    }

    public enum TaskListKind: String, Sendable, Hashable, CaseIterable {
        case today, upcoming, overdue, inbox, anytime, completed, projects
    }

    public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
        case general, assistant, notifications, sync, plugins, privacy, diagnostics
    }
}

/// Parses and builds `lumen://` deep links.
///
/// Supported forms:
/// `lumen://home`, `lumen://tasks/today`, `lumen://calendar`, `lumen://library`, `lumen://assistant`,
/// `lumen://automations`, `lumen://insights`, `lumen://notifications`, `lumen://settings/sync`,
/// `lumen://search?q=…`, `lumen://entity/task:<UUID>`, `lumen://capture?text=…`, `lumen://new/note`
public enum DeepLink {
    public static let scheme = "lumen"

    public static func destination(from url: URL) -> AppDestination? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "home": return .home
        case "calendar": return .calendar
        case "library": return .library
        case "assistant": return .assistant
        case "automations": return .automations
        case "insights": return .insights
        case "notifications": return .notifications
        case "tasks":
            guard let first = path.first else { return .tasks(.today) }
            return AppDestination.TaskListKind(rawValue: first.lowercased()).map(AppDestination.tasks)
        case "settings":
            guard let first = path.first else { return .settings(.general) }
            return AppDestination.SettingsSection(rawValue: first.lowercased()).map(AppDestination.settings)
        case "search":
            return .search(query: query["q"]?.nonBlank)
        case "capture":
            return .capture(text: query["text"]?.nonBlank)
        case "new":
            guard let first = path.first else { return nil }
            return AppDestination.CreationKind(rawValue: first.lowercased()).map(AppDestination.create)
        case "entity":
            guard let first = path.first, let reference = EntityReference(uri: first) else { return nil }
            return .entity(reference)
        default:
            return nil
        }
    }

    public static func url(for destination: AppDestination) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch destination {
        case .home: components.host = "home"
        case .calendar: components.host = "calendar"
        case .library: components.host = "library"
        case .assistant: components.host = "assistant"
        case .automations: components.host = "automations"
        case .insights: components.host = "insights"
        case .notifications: components.host = "notifications"
        case .tasks(let kind):
            components.host = "tasks"
            components.path = "/\(kind.rawValue)"
        case .settings(let section):
            components.host = "settings"
            components.path = "/\(section.rawValue)"
        case .search(let query):
            components.host = "search"
            if let query { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        case .capture(let text):
            components.host = "capture"
            if let text { components.queryItems = [URLQueryItem(name: "text", value: text)] }
        case .entity(let reference):
            components.host = "entity"
            components.path = "/\(reference.uri)"
        case .create(let kind):
            components.host = "new"
            components.path = "/\(kind.rawValue)"
        }
        return components.url
    }
}
