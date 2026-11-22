import Foundation
import LumenFoundation
import LumenOrganization

/// How busy a day is: shown as dots under the day in the month grid.
public struct DayDensity: Sendable, Hashable {
    public let events: Int
    public let tasks: Int

    public init(events: Int, tasks: Int) {
        self.events = events
        self.tasks = tasks
    }

    public static let empty = DayDensity(events: 0, tasks: 0)
    public var total: Int { events + tasks }
    public var isEmpty: Bool { total == 0 }
}

/// The weeks of one month, Monday first like the week strip, padded with the neighbouring months'
/// days so every week has seven. Pure `CalendarDate` arithmetic: independent of time zones.
public struct MonthGrid: Sendable, Hashable {
    public let year: Int
    public let month: Int
    public let firstOfMonth: CalendarDate
    /// Four to six weeks of seven days.
    public let weeks: [[CalendarDate]]

    public init(containing day: CalendarDate) {
        let first = day.adding(days: -(day.day - 1))
        let length = CalendarDate.daysInMonth(year: first.year, month: first.month)
        let last = first.adding(days: length - 1)
        let gridStart = first.adding(days: -(first.isoWeekday - 1))
        let gridEnd = last.adding(days: 7 - last.isoWeekday)
        let count = gridEnd.days(since: gridStart) + 1
        self.year = first.year
        self.month = first.month
        self.firstOfMonth = first
        self.weeks = stride(from: 0, to: count, by: 7).map { offset in
            (0..<7).map { gridStart.adding(days: offset + $0) }
        }
    }

    public var firstDay: CalendarDate { weeks.first?.first ?? firstOfMonth }
    public var lastDay: CalendarDate { weeks.last?.last ?? firstOfMonth }
    public var dayCount: Int { weeks.count * 7 }

    /// Whether `day` belongs to this month (rather than padding from a neighbouring month).
    public func contains(_ day: CalendarDate) -> Bool {
        day.year == year && day.month == month
    }

    /// The same day of the month `months` away, clamped to the target month's length
    /// (31 January + 1 month = 28 or 29 February).
    public static func day(_ day: CalendarDate, addingMonths months: Int) -> CalendarDate {
        let index = day.year * 12 + (day.month - 1) + months
        let year = index / 12
        let month = index % 12 + 1
        let clamped = min(day.day, CalendarDate.daysInMonth(year: year, month: month))
        return CalendarDate(year: year, month: month, day: clamped) ?? day
    }

    /// Events and tasks per day from an agenda covering the grid.
    public static func density(of agenda: [AgendaDay]) -> [CalendarDate: DayDensity] {
        var result: [CalendarDate: DayDensity] = [:]
        for day in agenda {
            var events = 0
            var tasks = 0
            for entry in day.allDay + day.scheduled + day.anytime {
                switch entry {
                case .event: events += 1
                case .task: tasks += 1
                }
            }
            result[day.day] = DayDensity(events: events, tasks: tasks)
        }
        return result
    }
}
