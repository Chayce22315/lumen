import Foundation
import LumenFoundation

/// Weekday and hour-of-day distributions, and how consistently days were active.
///
/// Tie-breaking is fixed so results are deterministic:
/// - **Weekdays** rank by average per occurrence (highest first), then by total (highest
///   first), then by position in the calendar's week (earliest first, so Monday before Tuesday
///   for a Monday-first calendar, Sunday first for a Sunday-first one).
/// - **Hours** rank by total (highest first), then by hour (earliest first).
/// A best weekday or hour exists only when it has a positive total.
public enum DistributionCalculator {
    /// One bucket per weekday, in the calendar's week order. Each bucket sums `values` on the
    /// days of `range` that fall on that weekday and counts how many such days the range has.
    public static func weekdays(_ values: [CalendarDate: Double], in range: DayRange, calendar: Calendar) -> [WeekdayBucket] {
        var totals: [Weekday: Double] = [:]
        var occurrences: [Weekday: Int] = [:]
        for day in range.days {
            let weekday = day.weekday
            occurrences[weekday, default: 0] += 1
            totals[weekday, default: 0] += values[day] ?? 0
        }
        return WeekMath.orderedWeekdays(for: calendar).map { weekday in
            WeekdayBucket(weekday: weekday, total: totals[weekday] ?? 0, dayCount: occurrences[weekday] ?? 0)
        }
    }

    /// 24 buckets, hours 0–23, with each hour's share of the overall total. Hours outside 0–23
    /// are ignored.
    public static func hours(_ totals: [Int: Double]) -> [HourBucket] {
        let valid = totals.filter { (0...23).contains($0.key) }
        let overall = valid.values.reduce(0, +)
        return (0...23).map { hour in
            let total = valid[hour] ?? 0
            return HourBucket(hour: hour, total: total, share: overall > 0 ? total / overall : 0)
        }
    }

    /// `buckets` ordered best first, using the weekday tie-breaking rules above.
    public static func rankedWeekdays(_ buckets: [WeekdayBucket], calendar: Calendar) -> [WeekdayBucket] {
        buckets.sorted { lhs, rhs in
            if lhs.average != rhs.average { return lhs.average > rhs.average }
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return WeekMath.position(of: lhs.weekday, calendar: calendar) < WeekMath.position(of: rhs.weekday, calendar: calendar)
        }
    }

    /// The best weekday, or `nil` when no weekday has a positive total.
    public static func bestWeekday(_ buckets: [WeekdayBucket], calendar: Calendar) -> WeekdayBucket? {
        rankedWeekdays(buckets, calendar: calendar).first.flatMap { $0.total > 0 ? $0 : nil }
    }

    /// `buckets` ordered best first, using the hour tie-breaking rules above.
    public static func rankedHours(_ buckets: [HourBucket]) -> [HourBucket] {
        buckets.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.hour < rhs.hour
        }
    }

    /// The best hour, or `nil` when no hour has a positive total.
    public static func bestHour(_ buckets: [HourBucket]) -> HourBucket? {
        rankedHours(buckets).first.flatMap { $0.total > 0 ? $0 : nil }
    }

    /// Share (0…1) of the days in `range` that are active. Active days outside the range are ignored.
    public static func consistency(activeDays: Set<CalendarDate>, in range: DayRange) -> Double {
        let active = activeDays.filter(range.contains).count
        return Double(active) / Double(range.dayCount)
    }
}
