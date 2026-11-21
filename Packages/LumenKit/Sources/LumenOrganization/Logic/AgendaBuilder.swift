import Foundation
import LumenFoundation

/// One row of the agenda.
public enum AgendaEntry: Sendable, Hashable, Identifiable {
    case event(EventOccurrence)
    case task(TaskItem)

    public var id: String {
        switch self {
        case .event(let occurrence): return "event:\(occurrence.id)"
        case .task(let task): return "task:\(task.id.uuidString)"
        }
    }
}

public struct AgendaDay: Sendable, Hashable, Identifiable {
    public let day: CalendarDate
    public let allDay: [AgendaEntry]
    /// Timed events and tasks with a due time, chronologically.
    public let scheduled: [AgendaEntry]
    /// Tasks due this day without a time.
    public let anytime: [AgendaEntry]

    public var id: CalendarDate { day }
    public var isEmpty: Bool { allDay.isEmpty && scheduled.isEmpty && anytime.isEmpty }
    public var entryCount: Int { allDay.count + scheduled.count + anytime.count }
}

/// Builds per-day agenda sections from tasks and event occurrences.
public enum AgendaBuilder {
    /// - Parameters:
    ///   - includeOverdueOnFirstDay: carries overdue open tasks into the first day (Today view).
    public static func agenda(
        days: [CalendarDate],
        tasks: [TaskItem],
        occurrences: [EventOccurrence],
        calendar: Calendar,
        includeOverdueOnFirstDay: Bool
    ) -> [AgendaDay] {
        guard let firstDay = days.first else { return [] }
        return days.map { day in
            let isFirst = day == firstDay
            let dayTasks = tasks.filter { task in
                guard task.isOpen, let due = task.dueDate else { return false }
                return due == day || (isFirst && includeOverdueOnFirstDay && due < day)
            }
            let dayEvents = occurrences.filter { $0.covers(day) }

            let allDay = dayEvents.filter(\.isAllDay)
                .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
                .map(AgendaEntry.event)

            var scheduledPairs: [(Date, Int, AgendaEntry)] = dayEvents.filter { !$0.isAllDay }.map { occurrence in
                // A multi-day timed event shows at midnight on its continuation days.
                let start = occurrence.firstDay == day ? occurrence.start : day.startDate(in: calendar)
                return (start, 0, .event(occurrence))
            }
            for task in dayTasks {
                if let time = task.dueTime, task.dueDate == day {
                    scheduledPairs.append((time.date(on: day, calendar: calendar), 1, .task(task)))
                }
            }
            scheduledPairs.sort { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2.id < rhs.2.id
            }

            let anytime = dayTasks
                .filter { $0.dueTime == nil || $0.dueDate != day }
                .sorted(by: TaskOrdering.actionableFirst)
                .map(AgendaEntry.task)

            return AgendaDay(day: day, allDay: allDay, scheduled: scheduledPairs.map(\.2), anytime: anytime)
        }
    }
}
