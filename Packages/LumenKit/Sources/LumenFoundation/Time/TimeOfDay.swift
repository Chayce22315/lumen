import Foundation

/// A wall-clock time without a date ("09:30"), combined with a `CalendarDate` at the edges.
public struct TimeOfDay: Hashable, Sendable, Codable, Comparable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.hour = components.hour ?? 0
        self.minute = components.minute ?? 0
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// The instant this time occurs on `day` in `calendar`'s time zone. On days where the time does
    /// not exist (a DST gap) the calendar resolves it to the next valid instant.
    public func date(on day: CalendarDate, calendar: Calendar) -> Date {
        let start = day.startDate(in: calendar)
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return calendar.date(byAdding: components, to: start) ?? start.addingTimeInterval(TimeInterval(minutesSinceMidnight * 60))
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    public static let midnight = TimeOfDay(uncheckedHour: 0, minute: 0)
    public static let nine = TimeOfDay(uncheckedHour: 9, minute: 0)

    private init(uncheckedHour hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

extension TimeOfDay: CustomStringConvertible {
    /// `HH:MM`, 24-hour.
    public var description: String {
        (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }
}
