import Foundation
import LumenCore

/// The widgets Home can show.
public enum DashboardWidgetKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case focus
    case agenda
    case projects
    case quickActions
    case suggestions
    case activity
    case insights
    case recentNotes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: return "Today's focus"
        case .agenda: return "Upcoming"
        case .projects: return "Active projects"
        case .quickActions: return "Quick actions"
        case .suggestions: return "Suggestions"
        case .activity: return "Recent activity"
        case .insights: return "Insights"
        case .recentNotes: return "Recent notes"
        }
    }

    public var symbolName: String {
        switch self {
        case .focus: return "scope"
        case .agenda: return "calendar"
        case .projects: return "square.stack.3d.up"
        case .quickActions: return "bolt"
        case .suggestions: return "lightbulb"
        case .activity: return "clock.arrow.circlepath"
        case .insights: return "chart.line.uptrend.xyaxis"
        case .recentNotes: return "doc.text"
        }
    }
}

public struct DashboardItem: Sendable, Hashable, Codable, Identifiable {
    public enum Size: String, Sendable, Hashable, Codable, CaseIterable {
        case compact
        case regular
        case expanded
    }

    public var kind: DashboardWidgetKind
    public var isVisible: Bool
    public var size: Size

    public var id: DashboardWidgetKind { kind }

    public init(kind: DashboardWidgetKind, isVisible: Bool = true, size: Size = .regular) {
        self.kind = kind
        self.isVisible = isVisible
        self.size = size
    }
}

/// The user's Home arrangement: order, visibility and size of each widget.
public struct DashboardLayout: Sendable, Hashable, Codable {
    public var items: [DashboardItem]

    public init(items: [DashboardItem]) {
        self.items = items
    }

    public static let standard = DashboardLayout(items: [
        DashboardItem(kind: .suggestions, size: .compact),
        DashboardItem(kind: .focus),
        DashboardItem(kind: .agenda),
        DashboardItem(kind: .quickActions, size: .compact),
        DashboardItem(kind: .projects),
        DashboardItem(kind: .insights, size: .compact),
        DashboardItem(kind: .recentNotes, isVisible: false),
        DashboardItem(kind: .activity, isVisible: false),
    ])

    public static let key = SettingKey("home.layout", default: DashboardLayout.standard)

    /// A layout with exactly one item per known kind: duplicates removed, missing kinds (added in
    /// newer versions) appended hidden, so stored layouts never break after an update.
    public var normalized: DashboardLayout {
        var seen = Set<DashboardWidgetKind>()
        var items = self.items.filter { seen.insert($0.kind).inserted }
        for kind in DashboardWidgetKind.allCases where !seen.contains(kind) {
            items.append(DashboardItem(kind: kind, isVisible: false))
        }
        return DashboardLayout(items: items)
    }

    public var visibleItems: [DashboardItem] { normalized.items.filter(\.isVisible) }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var normalizedItems = normalized.items
        let moving = source.sorted().compactMap { normalizedItems.indices.contains($0) ? normalizedItems[$0] : nil }
        let insertionBase = destination - source.filter { $0 < destination }.count
        normalizedItems.removeAll { item in moving.contains(item) }
        let index = min(max(insertionBase, 0), normalizedItems.count)
        normalizedItems.insert(contentsOf: moving, at: index)
        items = normalizedItems
    }

    public mutating func setVisible(_ visible: Bool, for kind: DashboardWidgetKind) {
        var normalizedItems = normalized.items
        if let index = normalizedItems.firstIndex(where: { $0.kind == kind }) {
            normalizedItems[index].isVisible = visible
        }
        items = normalizedItems
    }

    public mutating func setSize(_ size: DashboardItem.Size, for kind: DashboardWidgetKind) {
        var normalizedItems = normalized.items
        if let index = normalizedItems.firstIndex(where: { $0.kind == kind }) {
            normalizedItems[index].size = size
        }
        items = normalizedItems
    }
}
