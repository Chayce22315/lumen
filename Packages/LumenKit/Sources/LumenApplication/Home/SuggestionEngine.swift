import Foundation
import LumenFoundation

/// A suggestion on Home. Every suggestion is backed by real data and leads somewhere real.
public struct Suggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case reviewOverdue
        case planToday
        case projectNeedsNextAction
        case reviewSyncConflicts
        case setUpAssistant
        case readNotifications
        case keepStreak
        case celebrate
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let symbolName: String
    public let destination: AppDestination
    /// Higher shows first.
    public let priority: Int

    public var id: String {
        switch destination {
        case .entity(let reference): return "\(kind.rawValue):\(reference.uri)"
        default: return kind.rawValue
        }
    }
}

/// Facts the suggestion rules look at.
public struct SuggestionContext: Sendable, Hashable {
    public struct StalledProject: Sendable, Hashable {
        public let reference: EntityReference
        public let name: String

        public init(reference: EntityReference, name: String) {
            self.reference = reference
            self.name = name
        }
    }

    public var hour: Int
    public var overdue: Int
    public var dueToday: Int
    public var completedToday: Int
    public var openTasks: Int
    public var stalledProjects: [StalledProject]
    public var unreviewedConflicts: Int
    public var assistantConfigured: Bool
    public var unreadNotifications: Int
    public var currentStreak: Int

    public init(
        hour: Int,
        overdue: Int = 0,
        dueToday: Int = 0,
        completedToday: Int = 0,
        openTasks: Int = 0,
        stalledProjects: [StalledProject] = [],
        unreviewedConflicts: Int = 0,
        assistantConfigured: Bool = true,
        unreadNotifications: Int = 0,
        currentStreak: Int = 0
    ) {
        self.hour = hour
        self.overdue = overdue
        self.dueToday = dueToday
        self.completedToday = completedToday
        self.openTasks = openTasks
        self.stalledProjects = stalledProjects
        self.unreviewedConflicts = unreviewedConflicts
        self.assistantConfigured = assistantConfigured
        self.unreadNotifications = unreadNotifications
        self.currentStreak = currentStreak
    }
}

/// Rule-based suggestions. Deterministic, explainable and free; the assistant can add more on
/// request, but Home never waits on a model.
public enum SuggestionEngine {
    public static func suggestions(for context: SuggestionContext, limit: Int = 3) -> [Suggestion] {
        var result: [Suggestion] = []

        if context.unreviewedConflicts > 0 {
            result.append(Suggestion(
                kind: .reviewSyncConflicts,
                title: context.unreviewedConflicts == 1 ? "Review a sync conflict" : "Review \(context.unreviewedConflicts) sync conflicts",
                detail: "Two devices changed the same thing. Lumen kept the newer edit; you can restore the other.",
                symbolName: "arrow.triangle.2.circlepath",
                destination: .settings(.sync),
                priority: 90
            ))
        }
        if context.overdue > 0 {
            result.append(Suggestion(
                kind: .reviewOverdue,
                title: context.overdue == 1 ? "1 task is overdue" : "\(context.overdue) tasks are overdue",
                detail: "Reschedule, finish or let go of them to get a clear view of today.",
                symbolName: "clock.badge.exclamationmark",
                destination: .tasks(.overdue),
                priority: 80
            ))
        }
        if context.hour < 12, context.dueToday == 0, context.overdue == 0, context.openTasks > 0 {
            result.append(Suggestion(
                kind: .planToday,
                title: "Plan your day",
                detail: "Nothing is scheduled for today. Pick a few tasks to focus on.",
                symbolName: "sun.max",
                destination: .tasks(.anytime),
                priority: 60
            ))
        }
        for project in context.stalledProjects.prefix(2) {
            result.append(Suggestion(
                kind: .projectNeedsNextAction,
                title: "\(project.name) has no next step",
                detail: "Add the next task so the project keeps moving.",
                symbolName: "arrow.forward.circle",
                destination: .entity(project.reference),
                priority: 50
            ))
        }
        if context.currentStreak >= 2, context.completedToday == 0, context.hour >= 15 {
            result.append(Suggestion(
                kind: .keepStreak,
                title: "Keep your \(context.currentStreak)-day streak",
                detail: "Finish one task today to keep it going.",
                symbolName: "flame",
                destination: .tasks(.today),
                priority: 45
            ))
        }
        if context.unreadNotifications > 0 {
            result.append(Suggestion(
                kind: .readNotifications,
                title: context.unreadNotifications == 1 ? "1 unread notification" : "\(context.unreadNotifications) unread notifications",
                detail: "Reminders and automation results are waiting in your inbox.",
                symbolName: "bell.badge",
                destination: .notifications,
                priority: 30
            ))
        }
        if !context.assistantConfigured {
            result.append(Suggestion(
                kind: .setUpAssistant,
                title: "Set up the assistant",
                detail: "Connect a model provider to plan, search and create with natural language.",
                symbolName: "sparkles",
                destination: .settings(.assistant),
                priority: 20
            ))
        }
        if context.dueToday == 0, context.overdue == 0, context.completedToday >= 3 {
            result.append(Suggestion(
                kind: .celebrate,
                title: "Everything due today is done",
                detail: "\(context.completedToday) tasks finished. Enjoy the rest of the day.",
                symbolName: "checkmark.seal",
                destination: .tasks(.completed),
                priority: 10
            ))
        }

        return Array(result.sorted { ($0.priority, $1.id) > ($1.priority, $0.id) }.prefix(max(0, limit)))
    }
}
