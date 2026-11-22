import Foundation
import LumenFoundation

/// Human labels for days and times, relative to today. Locale and calendar are injected so the
/// output is predictable in tests and follows the user's settings in the app.
public struct DateLabels: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    public init(calendar: Calendar, locale: Locale) {
        self.calendar = calendar
        self.locale = locale
    }

    /// "Today", "Tomorrow", "Yesterday", a weekday within the coming week, else "21 Nov"
    /// (with the year when it differs from today's).
    public func dayLabel(_ day: CalendarDate, today: CalendarDate) -> String {
        let distance = day.days(since: today)
        switch distance {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return format(day, template: "EEEE")
        default: return format(day, template: day.year == today.year ? "d MMM" : "d MMM yyyy")
        }
    }

    /// Due label for a task row, including the time when set.
    public func dueLabel(day: CalendarDate, time: TimeOfDay?, today: CalendarDate) -> String {
        let label = dayLabel(day, today: today)
        guard let time else { return label }
        return "\(label), \(timeLabel(time))"
    }

    /// Localized wall-clock time ("15:00" or "3:00 PM" depending on the locale).
    public func timeLabel(_ time: TimeOfDay) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let reference = CalendarDate(year: 2000, month: 1, day: 3) ?? CalendarDate(Date(timeIntervalSince1970: 0), calendar: calendar)
        return formatter.string(from: time.date(on: reference, calendar: calendar))
    }

    public func timeLabel(_ date: Date) -> String {
        timeLabel(TimeOfDay(date, calendar: calendar))
    }

    /// "2 min ago", "3 h ago", "Yesterday", or a date for older instants.
    public func relativeLabel(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        let today = CalendarDate(now, calendar: calendar)
        let day = CalendarDate(date, calendar: calendar)
        if day == today { return "\(Int(seconds / 3_600)) h ago" }
        return dayLabel(day, today: today)
    }

    private func format(_ day: CalendarDate, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day.startDate(in: calendar))
    }
}
