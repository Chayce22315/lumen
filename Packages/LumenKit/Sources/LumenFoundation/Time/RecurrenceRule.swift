import Foundation

/// ISO weekday, Monday = 1 … Sunday = 7.
public enum Weekday: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }

    public var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
}

/// How a repeating schedule repeats. Shared by recurring tasks, calendar events, reminders and
/// scheduled automation triggers.
///
/// Day-of-month rules clamp rather than skip: "monthly on the 31st" occurs on the 30th in
/// 30-day months and on the last day of February, which is what people mean by it.
public struct RecurrenceRule: Sendable, Hashable, Codable {
    public enum Frequency: String, Sendable, Codable, Hashable, CaseIterable {
        case daily
        case weekly
        case monthly
        case yearly
    }

    public enum MonthlyPattern: Sendable, Hashable, Codable {
        /// The given day of the month, clamped to the month's length.
        case dayOfMonth(Int)
        case lastDayOfMonth
        /// `ordinal` 1…4 counts from the start of the month, -1 means the last such weekday.
        case weekdayOrdinal(ordinal: Int, weekday: Weekday)
    }

    public enum End: Sendable, Hashable, Codable {
        case never
        /// Total number of occurrences, counting the first one.
        case afterOccurrences(Int)
        /// Last allowed day, inclusive.
        case onDate(CalendarDate)
    }

    public var frequency: Frequency
    /// Repeat every `interval` periods (≥ 1).
    public var interval: Int
    /// Weekly only. Empty means "the anchor's weekday".
    public var weekdays: Set<Weekday>
    /// Monthly only. `nil` means "the anchor's day of month".
    public var monthlyPattern: MonthlyPattern?
    public var end: End

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: Set<Weekday> = [],
        monthlyPattern: MonthlyPattern? = nil,
        end: End = .never
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.monthlyPattern = monthlyPattern
        self.end = end
    }

    public static let daily = RecurrenceRule(frequency: .daily)
    public static let weekdaysOnly = RecurrenceRule(frequency: .weekly, weekdays: Weekday.weekdays)
    public static let weekly = RecurrenceRule(frequency: .weekly)
    public static let monthly = RecurrenceRule(frequency: .monthly)
    public static let yearly = RecurrenceRule(frequency: .yearly)
}

extension RecurrenceRule {
    /// A short human description: "Every 2 weeks on Mon, Wed".
    public var summary: String {
        let unit: String
        switch frequency {
        case .daily: unit = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly: unit = interval == 1 ? "Every week" : "Every \(interval) weeks"
        case .monthly: unit = interval == 1 ? "Every month" : "Every \(interval) months"
        case .yearly: unit = interval == 1 ? "Every year" : "Every \(interval) years"
        }
        var parts = [unit]
        if frequency == .weekly, !weekdays.isEmpty {
            if weekdays == Weekday.weekdays && interval == 1 {
                parts = ["Every weekday"]
            } else {
                parts.append("on " + weekdays.sorted().map(\.shortName).joined(separator: ", "))
            }
        }
        if frequency == .monthly, let monthlyPattern {
            switch monthlyPattern {
            case .dayOfMonth(let day): parts.append("on day \(day)")
            case .lastDayOfMonth: parts.append("on the last day")
            case .weekdayOrdinal(let ordinal, let weekday):
                let ordinalName = [1: "first", 2: "second", 3: "third", 4: "fourth", -1: "last"][ordinal] ?? "\(ordinal)th"
                parts.append("on the \(ordinalName) \(weekday.shortName)")
            }
        }
        switch end {
        case .never: break
        case .afterOccurrences(let count): parts.append("\(count) times")
        case .onDate(let date): parts.append("until \(date)")
        }
        return parts.joined(separator: " ")
    }
}
