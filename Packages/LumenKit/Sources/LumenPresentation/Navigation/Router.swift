import Foundation
import Observation
import LumenApplication

/// The app's top-level sections.
public enum AppTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case home
    case plan
    case library
    case assistant
    case search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .plan: return "Plan"
        case .library: return "Library"
        case .assistant: return "Assistant"
        case .search: return "Search"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: return "house"
        case .plan: return "checklist"
        case .library: return "books.vertical"
        case .assistant: return "sparkles"
        case .search: return "magnifyingglass"
        }
    }
}

/// Modal presentations.
public enum SheetRoute: Sendable, Hashable, Identifiable {
    case capture(text: String?)
    case create(AppDestination.CreationKind)
    case settings(AppDestination.SettingsSection)
    case commandPalette

    public var id: String {
        switch self {
        case .capture: return "capture"
        case .create(let kind): return "create.\(kind.rawValue)"
        case .settings(let section): return "settings.\(section.rawValue)"
        case .commandPalette: return "palette"
        }
    }
}

/// Navigation state for every tab. Every way into the app (taps, commands, deep links,
/// notifications, widgets, App Intents) goes through `open(_:)`.
@MainActor
@Observable
public final class Router {
    public var selectedTab: AppTab = .home
    public var homePath: [AppDestination] = []
    public var planPath: [AppDestination] = []
    public var libraryPath: [AppDestination] = []
    public var assistantPath: [AppDestination] = []
    public var searchPath: [AppDestination] = []
    public var sheet: SheetRoute?
    /// A query handed to the search tab by a deep link or command.
    public var pendingSearchQuery: String?

    public init() {}

    public func open(_ destination: AppDestination) {
        switch destination {
        case .home:
            sheet = nil
            selectedTab = .home
            homePath = []
        case .tasks(let kind):
            sheet = nil
            selectedTab = .plan
            planPath = [.tasks(kind)]
        case .calendar:
            sheet = nil
            selectedTab = .plan
            planPath = [.calendar]
        case .library:
            sheet = nil
            selectedTab = .library
            libraryPath = []
        case .assistant:
            sheet = nil
            selectedTab = .assistant
            assistantPath = []
        case .automations, .insights, .notifications:
            sheet = nil
            selectedTab = .home
            homePath = [destination]
        case .settings(let section):
            sheet = .settings(section)
        case .search(let query):
            sheet = nil
            selectedTab = .search
            pendingSearchQuery = query
        case .entity:
            sheet = nil
            push(destination)
        case .capture(let text):
            sheet = .capture(text: text)
        case .create(let kind):
            sheet = .create(kind)
        }
    }

    /// Pushes onto the selected tab's stack.
    public func push(_ destination: AppDestination) {
        switch selectedTab {
        case .home: homePath.append(destination)
        case .plan: planPath.append(destination)
        case .library: libraryPath.append(destination)
        case .assistant: assistantPath.append(destination)
        case .search: searchPath.append(destination)
        }
    }

    /// Re-selecting the current tab pops it to its root, as in system apps.
    public func select(_ tab: AppTab) {
        if tab == selectedTab {
            popToRoot(tab)
        } else {
            selectedTab = tab
        }
    }

    public func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .plan: planPath = []
        case .library: libraryPath = []
        case .assistant: assistantPath = []
        case .search: searchPath = []
        }
    }

    public func dismissSheet() {
        sheet = nil
    }
}
