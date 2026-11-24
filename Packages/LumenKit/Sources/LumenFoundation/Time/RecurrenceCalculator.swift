import Foundation

/// Expands a `RecurrenceRule` into concrete days. Pure and calendar-independent: all arithmetic
/// is done on `CalendarDate`, so results do not depend on time zones or DST.
public enum RecurrenceCalculator {
    /// Upper bound on periods examined per query; protects against pathological rules.
    static let maximumPeriods = 20_000

    /// Occurrences of a series anchored at `anchor` (its first occurrence), in order.
    ///
    /// - Parameters:
    ///   - after: only return occurrences strictly after this day.
    ///   - through: stop after this day (inclusive).
    ///   - limit: maximum number of results.
    public static func occurrences(
        of rule: RecurrenceRule,
        anchor: CalendarDate,
        after: CalendarDate? = nil,
        through: CalendarDate? = nil,
        limit: Int
    ) -> [CalendarDate] {
        guard limit > 0 else { return [] }
        var results: [CalendarDate] = []
        var produced = 0
        var period = 0
        while period < maximumPeriods {
            let candidates = days(inPeriod: period, rule: rule, anchor: anchor)
            for day in candidates where day >= anchor {
                produced += 1
                if case .afterOccurrences(let count) = rule.end, produced > count { return results }
                if case .onDate(let until) = rule.end, day > until { return results }
                if let through, day > through { return results }
                if let after, day <= after { continue }
                results.append(day)
                if results.count == limit { return results }
            }
            period += 1
        }
        return results
    }

    /// The first occurrence strictly after `day`, or `nil` when the series has ended.
    public static func nextOccurrence(of rule: RecurrenceRule, anchor: CalendarDate, after day: CalendarDate) -> CalendarDate? {
        occurrences(of: rule, anchor: anchor, after: day, limit: 1).first
    }

    /// Whether `day` is an occurrence of the series.
    public static func occurs(_ rule: RecurrenceRule, anchor: CalendarDate, on day: CalendarDate) -> Bool {
        guard day >= anchor else { return false }
        return occurrences(of: rule, anchor: anchor, after: day.adding(days: -1), through: day, limit: 1).first == day
    }

    /// Candidate days in period number `period` (0-based, already multiplied by the interval
    /// internally), sorted ascending. Candidates may precede the anchor in period 0.
    static func days(inPeriod period: Int, rule: RecurrenceRule, anchor: CalendarDate) -> [CalendarDate] {
        let step = period * rule.interval
        switch rule.frequency {
        case .daily:
            return [anchor.adding(days: step)]

        case .weekly:
            let mondayOfAnchorWeek = anchor.adding(days: -(anchor.isoWeekday - 1))
            let weekStart = mondayOfAnchorWeek.adding(days: 7 * step)
            let weekdays = rule.weekdays.isEmpty ? [anchor.isoWeekday] : rule.weekdays.map(\.rawValue).sorted()
            return weekdays.map { weekStart.adding(days: $0 - 1) }

        case .monthly:
            let monthIndex = (anchor.year * 12 + (anchor.month - 1)) + step
            let year = monthIndex / 12
            let month = monthIndex % 12 + 1
            guard let day = monthlyDay(year: year, month: month, pattern: rule.monthlyPattern ?? .dayOfMonth(anchor.day)) else {
                return []
            }
            return [day]

        case .yearly:
            let year = anchor.year + step
            let day = min(anchor.day, CalendarDate.daysInMonth(year: year, month: anchor.month))
            return CalendarDate(year: year, month: anchor.month, day: day).map { [$0] } ?? []
        }
    }

    static func monthlyDay(year: Int, month: Int, pattern: RecurrenceRule.MonthlyPattern) -> CalendarDate? {
        let length = CalendarDate.daysInMonth(year: year, month: month)
        guard length > 0 else { return nil }
        switch pattern {
        case .dayOfMonth(let requested):
            return CalendarDate(year: year, month: month, day: min(max(1, requested), length))
        case .lastDayOfMonth:
            return CalendarDate(year: year, month: month, day: length)
        case .weekdayOrdinal(let ordinal, let weekday):
            guard let first = CalendarDate(year: year, month: month, day: 1),
                  let last = CalendarDate(year: year, month: month, day: length) else { return nil }
            if ordinal == -1 {
                let back = (last.isoWeekday - weekday.rawValue + 7) % 7
                return last.adding(days: -back)
            }
            guard (1...5).contains(ordinal) else { return nil }
            let forward = (weekday.rawValue - first.isoWeekday + 7) % 7
            let day = first.adding(days: forward + 7 * (ordinal - 1))
            // A fifth Tuesday does not exist in every month; skip those months.
            return day.month == month ? day : nil
        }
    }
}
