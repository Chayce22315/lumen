import Foundation
import Observation
import LumenFoundation
import LumenKnowledge
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

/// A request for the search field of `section` to take keyboard focus (⌘F).
public struct SearchFocusRequest: Sendable, Hashable {
    public let section: NavigationSection
    /// Distinguishes repeated requests for the same section.
    public let serial: Int
}

/// Navigation state for every section. Every way into the app (taps, commands, deep links,
/// notifications, widgets, App Intents, keyboard shortcuts) goes through `open(_:)` or
/// `perform(_:)`.
///
/// Each section keeps its own path. In the tab bar a path is the section's navigation stack. In
/// the sidebar, a list/detail section (`NavigationSection.presentsListAndDetail`) keeps its
/// list's selection as the first element of its path and the screens pushed on the detail column
/// after it, so a layout change carries the user's place across unchanged.
@MainActor
@Observable
public final class Router {
    public private(set) var layout: NavigationLayout = .tabBar
    public private(set) var selection: NavigationSection = .home {
        didSet {
            if selection.isPlanSection { lastPlanSection = selection }
        }
    }
    public var homePath: [AppDestination] = []
    public var planPath: [AppDestination] = []
    public var libraryPath: [AppDestination] = []
    public var assistantPath: [AppDestination] = []
    public var searchPath: [AppDestination] = []
    public var sheet: SheetRoute?
    /// A query handed to the search tab by a deep link or command.
    public var pendingSearchQuery: String?
    /// Set by ⌘F; the screen owning that section's search field claims it.
    public private(set) var searchFocusRequest: SearchFocusRequest?
    /// The Plan destination last selected in the sidebar: where ⌘2 and the Plan tab return to.
    public private(set) var lastPlanSection: NavigationSection = .tasks(.today)

    /// Paths of the sections only the sidebar shows.
    private var sidebarPaths: [NavigationSection: [AppDestination]] = [:]
    private var searchFocusSerial = 0

    public init() {}

    /// The tab that holds the selection. Setting it selects that tab (in the sidebar, Plan's last
    /// destination) without changing its path.
    public var selectedTab: AppTab {
        get { selection.tab }
        set { selection = section(for: newValue) }
    }

    // MARK: - Destinations

    public func open(_ destination: AppDestination) {
        switch destination {
        case .home:
            show(.home, path: [])
        case .tasks(let kind):
            showRoot(of: .tasks(kind))
        case .calendar:
            showRoot(of: .calendar)
        case .library:
            show(.library, path: [])
        case .assistant:
            show(.assistant, path: [])
        case .automations, .insights:
            switch layout {
            case .tabBar: show(.home, path: [destination])
            case .sidebar: showRoot(of: NavigationSection(root: destination) ?? .home)
            }
        case .notifications:
            show(.home, path: [destination])
        case .settings(let section):
            sheet = .settings(section)
        case .search(let query):
            sheet = nil
            selection = .search
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

    /// Selects `section` and makes `destination` its only screen: the detail of a list/detail
    /// section in the sidebar, the one screen pushed on a stack otherwise.
    public func show(_ destination: AppDestination, in section: NavigationSection) {
        show(section, path: [destination])
    }

    /// Pushes onto the selected section's stack (in the sidebar's list/detail sections, the
    /// detail column; with nothing selected yet, the destination becomes the selection).
    public func push(_ destination: AppDestination) {
        setPath(path(for: selection) + [destination], for: selection)
    }

    // MARK: - Selection

    /// Re-selecting the current section pops it to its root, as in system apps.
    public func select(section: NavigationSection) {
        if section == selection {
            popToRoot(section)
        } else {
            selection = section
        }
    }

    /// Selects a tab: in the sidebar, Plan selects its last destination. Re-selecting pops to the root.
    public func select(_ tab: AppTab) {
        select(section: section(for: tab))
    }

    /// Switches to a tab without popping it (⌘1…⌘5) and closes any sheet.
    public func activate(_ tab: AppTab) {
        sheet = nil
        selection = section(for: tab)
    }

    public func popToRoot(_ section: NavigationSection) {
        setPath([], for: section)
    }

    public func dismissSheet() {
        sheet = nil
    }

    /// Closes the command palette, and only the palette: a command it ran may have opened
    /// another sheet in its place.
    public func dismissCommandPalette() {
        if sheet == .commandPalette { sheet = nil }
    }

    // MARK: - Paths

    public func path(for section: NavigationSection) -> [AppDestination] {
        switch section {
        case .home: return homePath
        case .plan: return planPath
        case .library: return libraryPath
        case .assistant: return assistantPath
        case .search: return searchPath
        case .tasks, .calendar, .automations, .collection, .insights: return sidebarPaths[section] ?? []
        }
    }

    public func setPath(_ path: [AppDestination], for section: NavigationSection) {
        switch section {
        case .home: homePath = path
        case .plan: planPath = path
        case .library: libraryPath = path
        case .assistant: assistantPath = path
        case .search: searchPath = path
        case .tasks, .calendar, .automations, .collection, .insights:
            sidebarPaths[section] = path.isEmpty ? nil : path
        }
    }

    /// The item a list/detail section shows in its detail column.
    public func listSelection(in section: NavigationSection) -> AppDestination? {
        path(for: section).first
    }

    /// Selecting a row replaces the detail column, including anything pushed on it.
    public func setListSelection(_ destination: AppDestination?, in section: NavigationSection) {
        guard listSelection(in: section) != destination else { return }
        setPath(destination.map { [$0] } ?? [], for: section)
    }

    /// The screens pushed on top of the selection in a list/detail section's detail column.
    public func detailPath(in section: NavigationSection) -> [AppDestination] {
        Array(path(for: section).dropFirst())
    }

    public func setDetailPath(_ detail: [AppDestination], in section: NavigationSection) {
        guard let selected = listSelection(in: section) else {
            setPath(detail, for: section)
            return
        }
        setPath([selected] + detail, for: section)
    }

    // MARK: - Layout

    /// Moves between the tab bar and the sidebar, carrying every section's place across: Plan's
    /// stack becomes the sidebar item it shows (and back), as do a collection opened in the
    /// Library and Insights opened on Home.
    public func setLayout(_ newLayout: NavigationLayout) {
        guard newLayout != layout else { return }
        switch newLayout {
        case .sidebar: moveIntoSidebar()
        case .tabBar: moveIntoTabBar()
        }
        layout = newLayout
    }

    private func moveIntoSidebar() {
        // Plan's stack always moves: the sidebar has no Plan overview to keep it in.
        var planTarget: NavigationSection?
        if let root = planPath.first {
            if let section = NavigationSection(root: root), section.isPlanSection {
                sidebarPaths[section] = planPath.count > 1 ? Array(planPath.dropFirst()) : nil
                planTarget = section
            } else {
                // Screens pushed straight onto the overview (a search result, a link) stay in
                // front, in the Plan destination last used.
                sidebarPaths[lastPlanSection] = planPath
                planTarget = lastPlanSection
            }
            lastPlanSection = planTarget ?? lastPlanSection
            planPath = []
        }
        switch selection {
        case .plan:
            selection = planTarget ?? lastPlanSection
        case .home, .library:
            // Insights opened on Home, or a collection opened in the Library, have their own items.
            let path = path(for: selection)
            if let root = path.first, let section = NavigationSection(root: root), NavigationSection(section.tab) == selection {
                sidebarPaths[section] = path.count > 1 ? Array(path.dropFirst()) : nil
                setPath([], for: selection)
                selection = section
            }
        default:
            break
        }
    }

    private func moveIntoTabBar() {
        let selected = selection
        // Plan's destination becomes the Plan tab's stack when it is selected or holds a place.
        let planSection = selected.isPlanSection ? selected : lastPlanSection
        let planState = path(for: planSection)
        if selected.isPlanSection || !planState.isEmpty, let root = planSection.rootDestination {
            planPath = [root] + planState
            sidebarPaths[planSection] = nil
        }
        switch selected {
        case .tasks, .calendar, .automations:
            selection = .plan
        case .collection, .insights:
            let host = NavigationSection(selected.tab)
            if let root = selected.rootDestination {
                setPath([root] + path(for: selected), for: host)
            }
            sidebarPaths[selected] = nil
            selection = host
        default:
            break
        }
    }

    /// Forgets collections that no longer exist; when the selected one is gone, shows the Library.
    public func retainCollections(_ existing: Set<NoteCollection.ID>) {
        let stale = sidebarPaths.keys.filter { section in
            if case .collection(let id) = section { return !existing.contains(id) }
            return false
        }
        for section in stale {
            sidebarPaths[section] = nil
        }
        if case .collection(let id) = selection, !existing.contains(id) {
            selection = .library
        }
    }

    // MARK: - Commands

    public func perform(_ command: AppCommand) {
        switch command {
        case .commandPalette:
            sheet = sheet == .commandPalette ? nil : .commandPalette
        case .quickCapture:
            open(.capture(text: nil))
        case .newNote:
            open(.create(.note))
        case .find:
            requestSearchFocus()
        case .settings:
            open(.settings(.general))
        case .showSection(let tab):
            activate(tab)
        }
    }

    /// ⌘F: focuses the search field of the current section's list, or universal search where
    /// the section has none. In the tab bar (and on the Search stack) the section first returns
    /// to its root screen, where the field is.
    public func requestSearchFocus() {
        // The palette's own field already has focus.
        guard sheet != .commandPalette else { return }
        sheet = nil
        var target = selection
        if !target.hasListSearch {
            target = .search
            selection = .search
        }
        if layout == .tabBar || !target.presentsListAndDetail {
            popToRoot(target)
        }
        searchFocusSerial += 1
        searchFocusRequest = SearchFocusRequest(section: target, serial: searchFocusSerial)
    }

    /// Called by the screen that owns `section`'s search field when a request may be pending;
    /// true (and the request is cleared) when the field should take focus.
    public func claimSearchFocus(in section: NavigationSection) -> Bool {
        guard searchFocusRequest?.section == section else { return false }
        searchFocusRequest = nil
        return true
    }

    // MARK: - Helpers

    /// The section a tab selects in the current layout.
    private func section(for tab: AppTab) -> NavigationSection {
        if layout == .sidebar && tab == .plan { return lastPlanSection }
        return NavigationSection(tab)
    }

    private func show(_ section: NavigationSection, path: [AppDestination]) {
        sheet = nil
        selection = section
        setPath(path, for: section)
    }

    /// Opens a sidebar item at its root, or, in the tab bar, pushes it as the only screen of its tab.
    private func showRoot(of section: NavigationSection) {
        switch layout {
        case .sidebar:
            show(section, path: [])
        case .tabBar:
            show(NavigationSection(section.tab), path: section.rootDestination.map { [$0] } ?? [])
        }
    }
}
