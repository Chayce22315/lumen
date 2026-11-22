import Foundation
import LumenFoundation

/// Activity on one weekday across a range of days.
public struct WeekdayBucket: Sendable, Hashable, Codable, Identifiable {
    public let weekday: Weekday
    /// Sum of the values on every occurrence of this weekday in the range.
    public let total: Double
    /// How many times this weekday occurs in the range.
    public let dayCount: Int

    public init(weekday: Weekday, total: Double, dayCount: Int) {
        self.weekday = weekday
        self.total = total
        self.dayCount = max(0, dayCount)
    }

    public var id: Weekday { weekday }

    /// Average per occurrence, so ranges that contain some weekdays more often than others
    /// compare fairly. 0 when the weekday does not occur in the range.
    public var average: Double {
        dayCount > 0 ? total / Double(dayCount) : 0
    }
}

/// Activity in one hour of the day.
public struct HourBucket: Sendable, Hashable, Codable, Identifiable {
    /// 0–23.
    public let hour: Int
    public let total: Double
    /// Fraction of all activity (0…1) that happened in this hour; 0 when there was none.
    public let share: Double

    public init(hour: Int, total: Double, share: Double) {
        self.hour = hour
        self.total = total
        self.share = share
    }

    public var id: Int { hour }
}

/// A run of consecutive active days.
public struct Streak: Sendable, Hashable, Codable {
    public let start: CalendarDate
    public let end: CalendarDate

    public init(start: CalendarDate, end: CalendarDate) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// Number of days in the streak.
    public var length: Int { end.days(since: start) + 1 }

    public var range: DayRange { DayRange(start: start, end: end) }
}
