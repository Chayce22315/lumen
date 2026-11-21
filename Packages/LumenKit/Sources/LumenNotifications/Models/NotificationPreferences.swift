import Foundation
import LumenCore

/// A daily window during which system alerts are held back. May wrap midnight (22:00–07:00).
public struct QuietHours: Sendable, Hashable, Codable {
    /// Minutes after midnight, `0..<1440`.
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = ((startMinute % 1440) + 1440) % 1440
        self.endMinute = ((endMinute % 1440) + 1440) % 1440
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let minute = Self.minuteOfDay(date, calendar: calendar)
        if startMinute == endMinute { return false }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    /// `date` itself when outside quiet hours, otherwise the moment quiet hours end.
    public func nextAllowedDate(onOrAfter date: Date, calendar: Calendar) -> Date {
        guard contains(date, calendar: calendar) else { return date }
        let minute = Self.minuteOfDay(date, calendar: calendar)
        let startOfDay = calendar.startOfDay(for: date)
        // If the window wraps midnight and we're in its evening part, it ends tomorrow.
        let endsTomorrow = startMinute > endMinute && minute >= startMinute
        let dayStart = endsTomorrow ? (calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay) : startOfDay
        return calendar.date(byAdding: .minute, value: endMinute, to: dayStart) ?? date
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

public struct CategoryPreference: Sendable, Hashable, Codable {
    /// Keep an entry in the in-app inbox.
    public var showsInInbox: Bool
    /// Deliver a system notification (banner / lock screen).
    public var deliversAlert: Bool

    public init(showsInInbox: Bool = true, deliversAlert: Bool = true) {
        self.showsInInbox = showsInInbox
        self.deliversAlert = deliversAlert
    }
}

public struct NotificationPreferences: Sendable, Hashable, Codable {
    public var categories: [NotificationCategory: CategoryPreference]
    public var quietHours: QuietHours?

    public init(categories: [NotificationCategory: CategoryPreference] = [:], quietHours: QuietHours? = nil) {
        self.categories = categories
        self.quietHours = quietHours
    }

    public func preference(for category: NotificationCategory) -> CategoryPreference {
        categories[category] ?? Self.defaultPreference(for: category)
    }

    static func defaultPreference(for category: NotificationCategory) -> CategoryPreference {
        switch category {
        case .insight, .system:
            return CategoryPreference(showsInInbox: true, deliversAlert: false)
        default:
            return CategoryPreference(showsInInbox: true, deliversAlert: true)
        }
    }

    public static let key = SettingKey("notifications.preferences", default: NotificationPreferences())
}
