import Foundation
import LumenFoundation

/// Converts between Lumen's `RecurrenceRule` and the system store's rule vocabulary.
///
/// The two do not mean exactly the same thing in every case. Lumen clamps day-of-month rules to
/// short months ("the 31st" lands on the 30th) while the system store skips those months, and the
/// system store may count weeks from Sunday. Every such difference is returned as a note for the
/// interface to show; nothing is changed silently.
public enum ExternalRecurrenceMapping {
    public struct Outbound: Sendable, Hashable {
        public let recurrence: ExternalRecurrence
        /// Where the system calendar will repeat differently from what Lumen would do.
        public let notes: [String]
    }

    public struct Inbound: Sendable, Hashable {
        /// `nil` when the stored rule can't be expressed as a `RecurrenceRule`.
        public let rule: RecurrenceRule?
        /// Why the rule can't be edited in Lumen, when it can't.
        public let note: String?
    }

    /// The system-store form of `rule` for a series whose first occurrence is on `anchor`.
    public static func outbound(_ rule: RecurrenceRule, anchor: CalendarDate, calendar: Calendar) -> Outbound {
        var notes: [String] = []
        var result = ExternalRecurrence(frequency: frequency(rule.frequency), interval: rule.interval, end: end(rule.end, calendar: calendar))
        switch rule.frequency {
        case .daily:
            break
        case .weekly:
            let anchorWeekday = Weekday(rawValue: anchor.isoWeekday) ?? .monday
            let days = rule.weekdays.isEmpty ? [anchorWeekday] : rule.weekdays.sorted()
            result.daysOfWeek = days.map { ExternalRecurrence.DayOfWeek(weekday: $0) }
            if rule.interval > 1, days.count > 1, days.contains(.sunday) {
                notes.append("The system calendar may start weeks on Sunday, so this every-\(rule.interval)-weeks event can fall on different Sundays than in Lumen.")
            }
        case .monthly:
            switch rule.monthlyPattern ?? .dayOfMonth(anchor.day) {
            case .dayOfMonth(let requested):
                let day = min(max(1, requested), 31)
                result.daysOfMonth = [day]
                if day >= 29 {
                    notes.append("In months without a day \(day), the system calendar skips this event; Lumen would move it to the month's last day.")
                }
            case .lastDayOfMonth:
                result.daysOfMonth = [-1]
            case .weekdayOrdinal(let ordinal, let weekday):
                result.daysOfWeek = [ExternalRecurrence.DayOfWeek(weekday: weekday, week: ordinal)]
            }
        case .yearly:
            if anchor.month == 2, anchor.day == 29 {
                notes.append("The system calendar repeats this event only in leap years; Lumen would use February 28 in other years.")
            }
        }
        return Outbound(recurrence: result, notes: notes)
    }

    /// The `RecurrenceRule` for a stored rule, or the reason there is none.
    public static func inbound(_ recurrence: ExternalRecurrence, calendar: Calendar) -> Inbound {
        func unsupported(_ pattern: String) -> Inbound {
            Inbound(rule: nil, note: "This event repeats \(pattern), which Lumen can't edit. Its repeat rule is kept unless you change it.")
        }
        guard recurrence.weeksOfYear.isEmpty, recurrence.daysOfYear.isEmpty, recurrence.setPositions.isEmpty else {
            return unsupported("on selected weeks or days of the year")
        }
        let end: RecurrenceRule.End
        switch recurrence.end {
        case .never: end = .never
        case .count(let count): end = .afterOccurrences(max(1, count))
        case .until(let date): end = .onDate(CalendarDate(date, calendar: calendar))
        }
        let interval = max(1, recurrence.interval)
        switch recurrence.frequency {
        case .daily:
            guard recurrence.daysOfWeek.isEmpty, recurrence.daysOfMonth.isEmpty, recurrence.monthsOfYear.isEmpty else {
                return unsupported("daily on selected days")
            }
            return Inbound(rule: RecurrenceRule(frequency: .daily, interval: interval, end: end), note: nil)

        case .weekly:
            guard recurrence.daysOfMonth.isEmpty, recurrence.monthsOfYear.isEmpty,
                  recurrence.daysOfWeek.allSatisfy({ $0.week == 0 }) else {
                return unsupported("weekly on numbered weeks")
            }
            let weekdays = Set(recurrence.daysOfWeek.map(\.weekday))
            return Inbound(rule: RecurrenceRule(frequency: .weekly, interval: interval, weekdays: weekdays, end: end), note: nil)

        case .monthly:
            guard recurrence.monthsOfYear.isEmpty else { return unsupported("in selected months") }
            let days = recurrence.daysOfMonth
            let weekdays = recurrence.daysOfWeek
            let pattern: RecurrenceRule.MonthlyPattern?
            if days.isEmpty, weekdays.isEmpty {
                pattern = nil
            } else if days == [-1], weekdays.isEmpty {
                pattern = .lastDayOfMonth
            } else if days.count == 1, let day = days.first, (1...31).contains(day), weekdays.isEmpty {
                pattern = .dayOfMonth(day)
            } else if days.isEmpty, weekdays.count == 1, let entry = weekdays.first, (1...5).contains(entry.week) || entry.week == -1 {
                pattern = .weekdayOrdinal(ordinal: entry.week, weekday: entry.weekday)
            } else {
                return unsupported("on several days of the month")
            }
            return Inbound(rule: RecurrenceRule(frequency: .monthly, interval: interval, monthlyPattern: pattern, end: end), note: nil)

        case .yearly:
            guard recurrence.daysOfWeek.isEmpty, recurrence.daysOfMonth.isEmpty, recurrence.monthsOfYear.count <= 1 else {
                return unsupported("yearly on a pattern of days")
            }
            return Inbound(rule: RecurrenceRule(frequency: .yearly, interval: interval, end: end), note: nil)
        }
    }

    private static func frequency(_ frequency: RecurrenceRule.Frequency) -> ExternalRecurrence.Frequency {
        switch frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    private static func end(_ end: RecurrenceRule.End, calendar: Calendar) -> ExternalRecurrence.End {
        switch end {
        case .never:
            return .never
        case .afterOccurrences(let count):
            return .count(max(1, count))
        case .onDate(let day):
            // Inclusive last day: anything starting before the next midnight.
            return .until(day.adding(days: 1).startDate(in: calendar).addingTimeInterval(-1))
        }
    }
}
