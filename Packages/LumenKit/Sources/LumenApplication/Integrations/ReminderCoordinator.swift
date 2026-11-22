import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization

/// Keeps system reminders in step with tasks and events: (re)schedules when they change,
/// cancels when they are completed or deleted, and rolls the event window forward daily.
public actor ReminderCoordinator {
    /// How far ahead event reminders are scheduled; refreshed on every launch and foreground.
    public static let eventHorizon: TimeInterval = 7 * 86_400

    private let tasks: TaskService
    private let calendars: CalendarService
    private let notifications: NotificationService
    private let events: EventBus
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let logger: Logger
    private var consumer: Task<Void, Never>?
    public private(set) var handledEvents = 0

    public init(tasks: TaskService, calendars: CalendarService, notifications: NotificationService, events: EventBus, timeSource: any TimeSource, calendar: Calendar, logger: Logger) {
        self.tasks = tasks
        self.calendars = calendars
        self.notifications = notifications
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
    }

    public func start() {
        guard consumer == nil else { return }
        // Only changes made by their owning module (or applied by sync). Notification events also
        // reference tasks; listening to those would re-trigger this coordinator on its own posts.
        let stream = events.events(matching: EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .calendarEvent]))
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self, let entity = event.entity else { continue }
                await self.refresh(entity)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
    }

    /// Re-plans reminders for one task or event.
    public func refresh(_ entity: EntityReference) async {
        defer { handledEvents += 1 }
        do {
            try await notifications.cancelPending(for: entity)
            switch entity.kind {
            case .task:
                guard let task = try await tasks.task(TaskItem.ID(entity.id)),
                      let planned = ReminderPlanner.reminder(for: task, now: timeSource.now(), calendar: calendar) else { return }
                try await post(planned)
            case .calendarEvent:
                guard let event = try await calendars.event(CalendarEvent.ID(entity.id)), !event.reminderOffsets.isEmpty else { return }
                try await scheduleEventReminders(event)
            default:
                return
            }
        } catch {
            logger.error("Reminder could not be scheduled", error: error, metadata: ["kind": entity.kind.rawValue])
        }
    }

    /// Re-plans every event reminder in the horizon (event reminders are rolling, task reminders
    /// are scheduled once and survive relaunches).
    public func refreshEventWindow() async {
        do {
            for event in try await calendars.allEvents() where !event.reminderOffsets.isEmpty {
                try await notifications.cancelPending(for: event.reference)
                try await scheduleEventReminders(event)
            }
        } catch {
            logger.error("Event reminders could not be refreshed", error: error)
        }
    }

    public func waitForHandledEvents(_ count: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while handledEvents < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func scheduleEventReminders(_ event: CalendarEvent) async throws {
        let now = timeSource.now()
        let occurrences = EventOccurrenceExpander.occurrences(of: event, color: .blue, from: now, to: now.addingTimeInterval(Self.eventHorizon), calendar: calendar)
        for planned in ReminderPlanner.reminders(for: occurrences, event: event, now: now, horizon: Self.eventHorizon) {
            try await post(planned)
        }
    }

    private func post(_ planned: PlannedReminder) async throws {
        // Reminders the user set explicitly are time-sensitive and ignore quiet hours.
        try await notifications.post(NotificationDraft(
            category: .reminder,
            title: planned.title,
            body: planned.body,
            entity: planned.entity,
            deliverAt: planned.fireDate,
            bypassesQuietHours: true
        ))
    }
}
