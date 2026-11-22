import Foundation
import LumenFoundation

/// An inclusive span of calendar days, the unit every analytics query and report works in.
///
/// A range always contains at least one day: the initializer orders its bounds, so
/// `DayRange(start: b, end: a)` is the same range as `DayRange(start: a, end: b)`.
public struct DayRange: Sendable, Hashable, CustomStringConvertible {
    public let start: CalendarDate
    public let end: CalendarDate

    public init(start: CalendarDate, end: CalendarDate) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// A single day.
    public init(day: CalendarDate) {
        self.init(start: day, end: day)
    }

    /// Number of days in the range, counting both ends.
    public var dayCount: Int {
        end.days(since: start) + 1
    }

    /// Every day of the range, in order.
    public var days: [CalendarDate] {
        (0..<dayCount).map { start.adding(days: $0) }
    }

    public func contains(_ day: CalendarDate) -> Bool {
        day >= start && day <= end
    }

    /// The same range moved by `offset` days (negative moves into the past).
    public func shifted(byDays offset: Int) -> DayRange {
        DayRange(start: start.adding(days: offset), end: end.adding(days: offset))
    }

    /// The range of the same length that ends the day before this one starts. A full calendar week
    /// maps to the previous week, a 30-day window to the 30 days before it.
    public var previousPeriod: DayRange {
        shifted(byDays: -dayCount)
    }

    /// The days this range shares with `other`, or `nil` when they do not overlap.
    public func intersection(_ other: DayRange) -> DayRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard lower <= upper else { return nil }
        return DayRange(start: lower, end: upper)
    }

    /// `description` is `YYYY-MM-DD…YYYY-MM-DD` (or a single day).
    public var description: String {
        start == end ? start.description : "\(start)…\(end)"
    }

    // MARK: - Common ranges

    /// The `count` days ending on (and including) `day`. `count` is clamped to at least one day.
    public static func lastDays(_ count: Int, endingOn day: CalendarDate) -> DayRange {
        DayRange(start: day.adding(days: -(max(1, count) - 1)), end: day)
    }

    /// The full calendar week containing `day`, starting on `calendar.firstWeekday`.
    public static func week(containing day: CalendarDate, calendar: Calendar) -> DayRange {
        let start = WeekMath.startOfWeek(containing: day, calendar: calendar)
        return DayRange(start: start, end: start.adding(days: 6))
    }

    /// This week so far: from the start of the week containing `today` (per
    /// `calendar.firstWeekday`) through `today`. Use `week(containing:calendar:)` for the full week.
    public static func thisWeek(today: CalendarDate, calendar: Calendar) -> DayRange {
        DayRange(start: WeekMath.startOfWeek(containing: today, calendar: calendar), end: today)
    }

    /// The full calendar month containing `day`.
    public static func month(containing day: CalendarDate) -> DayRange {
        let first = day.adding(days: -(day.day - 1))
        let length = CalendarDate.daysInMonth(year: day.year, month: day.month)
        return DayRange(start: first, end: first.adding(days: length - 1))
    }

    /// This month so far: from the first of the month through `today`.
    public static func thisMonth(today: CalendarDate) -> DayRange {
        DayRange(start: today.adding(days: -(today.day - 1)), end: today)
    }
}

extension DayRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Routed through the ordering initializer so a decoded range upholds the same invariant.
        self.init(
            start: try container.decode(CalendarDate.self, forKey: .start),
            end: try container.decode(CalendarDate.self, forKey: .end)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}
