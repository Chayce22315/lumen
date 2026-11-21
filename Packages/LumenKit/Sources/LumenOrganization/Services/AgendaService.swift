import Foundation
import LumenFoundation
import LumenCore

/// What the Today screen and dashboard need in one read.
public struct TodayOverview: Sendable, Hashable {
    public let day: CalendarDate
    public let summary: TaskSummary
    public let agenda: AgendaDay
    /// The next timed event that has not ended yet.
    public let nextEvent: EventOccurrence?
    /// Highest-ranked open tasks for today, including overdue ones.
    public let focusTasks: [TaskItem]
}

/// Combines tasks and calendar occurrences into day-by-day agendas.
public final class AgendaService: Sendable {
    private let tasks: TaskService
    private let calendars: CalendarService
    private let timeSource: any TimeSource
    private let calendar: Calendar

    public init(tasks: TaskService, calendars: CalendarService, timeSource: any TimeSource, calendar: Calendar) {
        self.tasks = tasks
        self.calendars = calendars
        self.timeSource = timeSource
        self.calendar = calendar
    }

    /// Agenda for `count` days starting at `first` (default today). Overdue tasks are carried into
    /// the first day when it is today.
    public func agenda(from first: CalendarDate? = nil, days count: Int) async throws -> [AgendaDay] {
        let today = CalendarDate(timeSource.now(), calendar: calendar)
        let start = first ?? today
        let days = (0..<max(1, min(count, 92))).map { start.adding(days: $0) }
        guard let last = days.last else { return [] }
        let windowStart = start.startDate(in: calendar)
        let windowEnd = last.adding(days: 1).startDate(in: calendar)
        async let occurrences = calendars.occurrences(from: windowStart, to: windowEnd)
        let openTasks = try await tasks.tasks(TaskQuery(statuses: [.todo, .inProgress], dueOnOrBefore: last))
        return AgendaBuilder.agenda(
            days: days,
            tasks: openTasks,
            occurrences: try await occurrences,
            calendar: calendar,
            includeOverdueOnFirstDay: start == today
        )
    }

    public func todayOverview(focusLimit: Int = 5) async throws -> TodayOverview {
        let now = timeSource.now()
        let today = CalendarDate(now, calendar: calendar)
        async let summary = tasks.summary()
        async let todayList = tasks.list(.today)
        let agenda = try await agenda(from: today, days: 1)
        let upcoming = try await calendars.occurrences(from: now, to: now.addingTimeInterval(7 * 86_400))
        let nextEvent = upcoming.first { !$0.isAllDay && $0.end > now }
        return TodayOverview(
            day: today,
            summary: try await summary,
            agenda: agenda.first ?? AgendaDay(day: today, allDay: [], scheduled: [], anytime: []),
            nextEvent: nextEvent,
            focusTasks: Array(try await todayList.prefix(max(0, focusLimit)))
        )
    }
}
