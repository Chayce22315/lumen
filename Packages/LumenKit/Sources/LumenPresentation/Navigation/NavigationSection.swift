import Foundation
import LumenFoundation
import LumenOrganization
import LumenKnowledge
import LumenApplication

/// How the root presents its sections.
public enum NavigationLayout: Sendable, Hashable {
    /// Five tabs, each a navigation stack: iPhone, and iPad at compact width.
    case tabBar
    /// A sidebar listing every destination, with list and detail side by side: iPad at regular width.
    case sidebar
}

/// A place the root can select: a tab of the tab bar, or an item of the iPad sidebar.
///
/// The five tabs (`home`, `plan`, `library`, `assistant`, `search`) are the tab bar. The sidebar
/// replaces the Plan overview with Plan's destinations and adds collections and Insights.
public enum NavigationSection: Sendable, Hashable, Identifiable {
    case home
    /// The Plan overview. Tab bar only: the sidebar lists Plan's destinations directly.
    case plan
    /// A smart list, or Projects. Sidebar only.
    case tasks(AppDestination.TaskListKind)
    /// Sidebar only.
    case calendar
    /// Sidebar only.
    case automations
    case library
    /// One collection's notes. Sidebar only.
    case collection(NoteCollection.ID)
    case assistant
    /// Sidebar only.
    case insights
    case search

    /// Plan's destinations in sidebar order.
    public static let planSections: [NavigationSection] =
        [.tasks(.today), .tasks(.upcoming), .tasks(.overdue), .tasks(.inbox), .tasks(.anytime), .tasks(.completed), .tasks(.projects), .calendar, .automations]

    public var id: String {
        switch self {
        case .home: return "home"
        case .plan: return "plan"
        case .tasks(let kind): return "tasks.\(kind.rawValue)"
        case .calendar: return "calendar"
        case .automations: return "automations"
        case .library: return "library"
        case .collection(let id): return "collection.\(id.uuidString)"
        case .assistant: return "assistant"
        case .insights: return "insights"
        case .search: return "search"
        }
    }

    /// The section a tab selects in the tab bar.
    public init(_ tab: AppTab) {
        switch tab {
        case .home: self = .home
        case .plan: self = .plan
        case .library: self = .library
        case .assistant: self = .assistant
        case .search: self = .search
        }
    }

    /// The sidebar item that shows `destination` as its own root screen, if there is one.
    public init?(root destination: AppDestination) {
        switch destination {
        case .tasks(let kind): self = .tasks(kind)
        case .calendar: self = .calendar
        case .automations: self = .automations
        case .insights: self = .insights
        case .entity(let reference) where reference.kind == .collection:
            self = .collection(reference.identifier(as: NoteCollection.self))
        default: return nil
        }
    }

    /// The tab that holds this section in the tab bar (and the ⌘-number that reaches it).
    public var tab: AppTab {
        switch self {
        case .home, .insights: return .home
        case .plan, .tasks, .calendar, .automations: return .plan
        case .library, .collection: return .library
        case .assistant: return .assistant
        case .search: return .search
        }
    }

    /// The screen this section shows when it is pushed onto its tab's stack in the tab bar.
    /// `nil` for the five tabs themselves.
    public var rootDestination: AppDestination? {
        switch self {
        case .home, .plan, .library, .assistant, .search: return nil
        case .tasks(let kind): return .tasks(kind)
        case .calendar: return .calendar
        case .automations: return .automations
        case .insights: return .insights
        case .collection(let id): return .entity(EntityReference(kind: .collection, id: id))
        }
    }

    public func isAvailable(in layout: NavigationLayout) -> Bool {
        switch self {
        case .home, .library, .assistant, .search: return true
        case .plan: return layout == .tabBar
        case .tasks, .calendar, .automations, .collection, .insights: return layout == .sidebar
        }
    }

    /// One of Plan's destinations in the sidebar.
    public var isPlanSection: Bool {
        switch self {
        case .tasks, .calendar, .automations: return true
        default: return false
        }
    }

    /// In the sidebar, the section shows a list with the selected item's detail beside it. Its
    /// path in the router holds both: the first element is the selection, the rest is pushed on
    /// the detail column.
    public var presentsListAndDetail: Bool {
        switch self {
        case .tasks, .automations, .library, .collection, .assistant: return true
        case .home, .plan, .calendar, .insights, .search: return false
        }
    }

    /// The section's root screen has a search field (⌘F focuses it).
    public var hasListSearch: Bool {
        self == .assistant || self == .search
    }

    /// The smart list a task section shows; `nil` for Projects and every other section.
    public var smartList: SmartList? {
        guard case .tasks(let kind) = self else { return nil }
        switch kind {
        case .today: return .today
        case .upcoming: return .upcoming
        case .overdue: return .overdue
        case .inbox: return .inbox
        case .anytime: return .anytime
        case .completed: return .completed
        case .projects: return nil
        }
    }

    /// The sidebar title. Collections are titled by their name, which the sidebar model provides.
    public var title: String {
        switch self {
        case .home: return AppTab.home.title
        case .plan: return AppTab.plan.title
        case .tasks(.projects): return "Projects"
        case .tasks: return smartList?.title ?? "Tasks"
        case .calendar: return "Calendar"
        case .automations: return "Automations"
        case .library: return AppTab.library.title
        case .collection: return "Collection"
        case .assistant: return AppTab.assistant.title
        case .insights: return "Insights"
        case .search: return AppTab.search.title
        }
    }

    public var symbolName: String {
        switch self {
        case .home: return AppTab.home.symbolName
        case .plan: return AppTab.plan.symbolName
        case .tasks(let kind):
            switch kind {
            case .today: return "sun.max"
            case .upcoming: return "calendar.day.timeline.left"
            case .overdue: return "clock.badge.exclamationmark"
            case .inbox: return "tray"
            case .anytime: return "square.grid.2x2"
            case .completed: return "checkmark.circle"
            case .projects: return "square.stack.3d.up"
            }
        case .calendar: return "calendar"
        case .automations: return "point.3.connected.trianglepath.dotted"
        case .library: return AppTab.library.symbolName
        case .collection: return "folder"
        case .assistant: return AppTab.assistant.symbolName
        case .insights: return "chart.line.uptrend.xyaxis"
        case .search: return AppTab.search.symbolName
        }
    }
}
