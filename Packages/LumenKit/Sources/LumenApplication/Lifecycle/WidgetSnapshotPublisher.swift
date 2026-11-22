import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenSync
import LumenWidgetData

/// Writes the widget snapshot after relevant changes (debounced) and asks WidgetKit to reload.
public actor WidgetSnapshotPublisher {
    private let store: WidgetSnapshotStore
    /// What the user did on widgets, next to the snapshot; applied by `LumenRuntime.applyWidgetActions()`.
    public nonisolated let actionQueue: WidgetActionQueue
    private let tasks: TaskService
    private let projects: ProjectService
    private let agenda: AgendaService
    private let events: EventBus
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let reload: @Sendable () -> Void
    private let logger: Logger
    private let debounce: TimeInterval
    private var consumer: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    public private(set) var writeCount = 0
    public private(set) var receivedEvents = 0

    init(
        store: WidgetSnapshotStore,
        tasks: TaskService,
        projects: ProjectService,
        agenda: AgendaService,
        events: EventBus,
        timeSource: any TimeSource,
        calendar: Calendar,
        reload: @escaping @Sendable () -> Void,
        logger: Logger,
        debounce: TimeInterval = 0.75
    ) {
        self.store = store
        self.actionQueue = WidgetActionQueue(directory: store.url.deletingLastPathComponent())
        self.tasks = tasks
        self.projects = projects
        self.agenda = agenda
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.reload = reload
        self.logger = logger
        self.debounce = debounce
    }

    public func start() {
        guard consumer == nil else { return }
        let stream = events.events(matching: EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .project, .calendarEvent, .systemCalendarEvent]))
        consumer = Task { [weak self] in
            for await _ in stream {
                await self?.scheduleRefresh()
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        pending?.cancel()
        pending = nil
    }

    private func scheduleRefresh() {
        receivedEvents += 1
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Builds and writes the snapshot now.
    @discardableResult
    public func refresh() async -> WidgetSnapshot? {
        do {
            let snapshot = try await makeSnapshot()
            try store.write(snapshot)
            writeCount += 1
            reload()
            return snapshot
        } catch {
            logger.error("Widget snapshot could not be written", error: error)
            return nil
        }
    }

    func makeSnapshot() async throws -> WidgetSnapshot {
        let now = timeSource.now()
        let today = CalendarDate(now, calendar: calendar)
        let overview = try await agenda.todayOverview(focusLimit: 6)
        let live = try await projects.liveProjectProgress()
        return WidgetSnapshot(
            generatedAt: now,
            dueToday: overview.summary.dueToday,
            overdue: overview.summary.overdue,
            completedToday: overview.summary.completedToday,
            tasks: overview.focusTasks.map { task in
                WidgetSnapshot.TaskLine(
                    id: task.id.rawValue,
                    title: task.title,
                    dueTime: task.dueTime?.description,
                    isOverdue: task.isOverdue(today: today),
                    priority: task.priority.rawValue,
                    isDueToday: task.dueDate == today
                )
            },
            nextEvent: overview.nextEvent.map { WidgetSnapshot.EventLine(title: $0.title, start: $0.start, end: $0.end, location: $0.location) },
            projects: live.filter { $0.project.status == .active }.prefix(4).map { pair in
                WidgetSnapshot.ProjectLine(id: pair.project.id.rawValue, name: pair.project.name, fractionComplete: pair.progress.fractionComplete, color: pair.project.color.rawValue)
            }
        )
    }
}
