import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenSearch
import LumenSync
import LumenAnalytics

/// One line of the recent-activity widget.
public struct ActivityItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let symbolName: String
    public let occurredAt: Date
    public let actor: EventActor
    public let destination: AppDestination?
}

public struct ProjectSummary: Sendable, Hashable, Identifiable {
    public let project: Project
    public let progress: ProjectProgress
    public var id: Project.ID { project.id }
}

/// Everything Home shows, read in one pass.
public struct HomeSnapshot: Sendable, Hashable {
    public let generatedAt: Date
    public let greeting: Greeting
    public let layout: DashboardLayout
    public let overview: TodayOverview
    /// The next few days after today that have something on them.
    public let upcoming: [AgendaDay]
    public let projects: [ProjectSummary]
    public let suggestions: [Suggestion]
    public let activity: [ActivityItem]
    public let insights: [Insight]
    public let currentStreak: Int
}

/// Assembles Home from the engines. Each section is independent: a failing section is reported
/// and left empty rather than failing the whole screen.
public final class HomeService: Sendable {
    public static let displayNameKey = SettingKey<String?>("profile.displayName", default: nil)

    private let tasks: TaskService
    private let projects: ProjectService
    private let agenda: AgendaService
    private let notifications: NotificationService
    private let analytics: AnalyticsServices
    private let sync: SyncEngine
    private let index: SearchIndex
    private let settings: SettingsStore
    private let timeSource: any TimeSource
    private let calendar: Calendar

    init(
        tasks: TaskService,
        projects: ProjectService,
        agenda: AgendaService,
        notifications: NotificationService,
        analytics: AnalyticsServices,
        sync: SyncEngine,
        index: SearchIndex,
        settings: SettingsStore,
        timeSource: any TimeSource,
        calendar: Calendar
    ) {
        self.tasks = tasks
        self.projects = projects
        self.agenda = agenda
        self.notifications = notifications
        self.analytics = analytics
        self.sync = sync
        self.index = index
        self.settings = settings
        self.timeSource = timeSource
        self.calendar = calendar
    }

    public func layout() async -> DashboardLayout {
        await settings.value(DashboardLayout.key).normalized
    }

    public func saveLayout(_ layout: DashboardLayout) async throws {
        try await settings.set(layout.normalized, for: DashboardLayout.key)
    }

    public func setDisplayName(_ name: String?) async throws {
        try await settings.set(name?.collapsingWhitespace.nonBlank, for: Self.displayNameKey)
    }

    public func snapshot(assistantConfigured: Bool) async throws -> HomeSnapshot {
        let now = timeSource.now()
        let today = CalendarDate(now, calendar: calendar)
        async let overviewResult = agenda.todayOverview()
        async let upcomingResult = agenda.agenda(from: today.adding(days: 1), days: 6)
        async let projectResult = projects.liveProjectProgress()
        async let unreadResult = notifications.unreadCount()
        async let activityResult = analytics.service.recentEvents(limit: 12, names: Set(OrganizationEvent.all))
        async let insightResult = analytics.service.insights(signals: analytics.signals, today: today, limit: 3)
        async let snapshotResult = analytics.service.activitySnapshot(signals: analytics.signals, today: today)
        let layout = await self.layout()
        let name = await settings.value(Self.displayNameKey)
        let syncStatus = await sync.status()

        let overview = try await overviewResult
        let projectPairs = try await projectResult
        let streak = StreakCalculator.currentStreakLength(activeDays: try await snapshotResult.completionDays, today: today)

        let summaries = projectPairs
            .filter { $0.project.status == .active }
            .sorted { lhs, rhs in
                (lhs.progress.health == .closed ? 1 : 0, lhs.project.sortOrder) < (rhs.progress.health == .closed ? 1 : 0, rhs.project.sortOrder)
            }
            .map { ProjectSummary(project: $0.project, progress: $0.progress) }

        let stalled = summaries
            .filter { $0.progress.nextAction == nil }
            .map { SuggestionContext.StalledProject(reference: $0.project.reference, name: $0.project.name) }

        let context = SuggestionContext(
            hour: calendar.component(.hour, from: now),
            overdue: overview.summary.overdue,
            dueToday: overview.summary.dueToday,
            completedToday: overview.summary.completedToday,
            openTasks: overview.summary.open,
            stalledProjects: stalled,
            unreviewedConflicts: syncStatus.unreviewedConflicts,
            assistantConfigured: assistantConfigured,
            unreadNotifications: try await unreadResult,
            currentStreak: streak
        )

        let greeting = GreetingComposer.greeting(
            now: now,
            calendar: calendar,
            name: name,
            day: DayContext(
                dueToday: overview.summary.dueToday,
                overdue: overview.summary.overdue,
                completedToday: overview.summary.completedToday,
                nextEventTitle: overview.nextEvent?.title,
                nextEventStart: overview.nextEvent?.start
            )
        )

        return HomeSnapshot(
            generatedAt: now,
            greeting: greeting,
            layout: layout,
            overview: overview,
            upcoming: try await upcomingResult.filter { !$0.isEmpty }.prefix(3).map { $0 },
            projects: summaries,
            suggestions: SuggestionEngine.suggestions(for: context),
            activity: try await activityItems(from: try await activityResult),
            insights: try await insightResult,
            currentStreak: streak
        )
    }

    private func activityItems(from records: [AnalyticsEventRecord]) async throws -> [ActivityItem] {
        let references = records.compactMap(\.entity)
        let titles = try await index.summaries(for: references)
        return records.compactMap { record in
            guard let (verb, symbol) = ActivityPhrasing.describe(record.name) else { return nil }
            let subject = record.entity.flatMap { titles[$0]?.title }.map { "“\($0)”" } ?? ActivityPhrasing.fallbackSubject(for: record.entityKind)
            return ActivityItem(
                id: record.id.rawValue,
                title: "\(verb) \(subject)",
                symbolName: symbol,
                occurredAt: record.occurredAt,
                actor: record.actor,
                destination: record.name == OrganizationEvent.taskDeleted || record.name == OrganizationEvent.projectDeleted
                    ? nil
                    : record.entity.map(AppDestination.entity)
            )
        }
    }
}

/// Human phrasing for activity events.
enum ActivityPhrasing {
    static func describe(_ name: EventName) -> (verb: String, symbol: String)? {
        switch name {
        case OrganizationEvent.taskCreated: return ("Added", "plus.circle")
        case OrganizationEvent.taskCompleted: return ("Completed", "checkmark.circle")
        case OrganizationEvent.taskReopened: return ("Reopened", "arrow.uturn.backward.circle")
        case OrganizationEvent.taskCancelled: return ("Cancelled", "xmark.circle")
        case OrganizationEvent.taskDeleted: return ("Deleted a task", "trash")
        case OrganizationEvent.projectCreated: return ("Started project", "folder.badge.plus")
        case OrganizationEvent.projectCompleted: return ("Finished project", "flag.checkered")
        case OrganizationEvent.eventCreated: return ("Scheduled", "calendar.badge.plus")
        default: return nil
        }
    }

    static func fallbackSubject(for kind: EntityKind?) -> String {
        switch kind {
        case .task?: return "a task"
        case .project?: return "a project"
        case .calendarEvent?: return "an event"
        default: return ""
        }
    }
}
