import Foundation
import LumenFoundation

/// Week arithmetic that honours the injected calendar's first weekday.
enum WeekMath {
    /// The calendar's first weekday as an ISO weekday. `Calendar.firstWeekday` counts Sunday = 1 …
    /// Saturday = 7; out-of-range values are wrapped rather than trusted.
    static func firstWeekday(of calendar: Calendar) -> Weekday {
        let gregorian = ((calendar.firstWeekday - 1) % 7 + 7) % 7 + 1 // 1 = Sunday … 7 = Saturday
        let iso = gregorian == 1 ? 7 : gregorian - 1
        return Weekday(rawValue: iso) ?? .monday // `iso` is always 1…7, so the fallback is unreachable.
    }

    /// The weekdays in display order for `calendar` (Monday-first or Sunday-first, …).
    static func orderedWeekdays(for calendar: Calendar) -> [Weekday] {
        let first = firstWeekday(of: calendar).rawValue
        return (0..<7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
    }

    /// The first day of the week that contains `day`.
    static func startOfWeek(containing day: CalendarDate, calendar: Calendar) -> CalendarDate {
        let offset = (day.isoWeekday - firstWeekday(of: calendar).rawValue + 7) % 7
        return day.adding(days: -offset)
    }

    /// Position of `weekday` within the calendar's week (0 for the first weekday).
    static func position(of weekday: Weekday, calendar: Calendar) -> Int {
        (weekday.rawValue - firstWeekday(of: calendar).rawValue + 7) % 7
    }
}

extension CalendarDate {
    /// The day's weekday.
    var weekday: Weekday {
        Weekday(rawValue: isoWeekday) ?? .monday // `isoWeekday` is always 1…7, so the fallback is unreachable.
    }
}

extension Weekday {
    /// English name used in insight and report text ("Tuesday").
    var fullName: String {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
}
