import Foundation
import LumenFoundation

public struct Greeting: Sendable, Hashable {
    public let title: String
    public let subtitle: String
}

/// What the greeting knows about the day.
public struct DayContext: Sendable, Hashable {
    public var dueToday: Int
    public var overdue: Int
    public var completedToday: Int
    public var nextEventTitle: String?
    public var nextEventStart: Date?

    public init(dueToday: Int = 0, overdue: Int = 0, completedToday: Int = 0, nextEventTitle: String? = nil, nextEventStart: Date? = nil) {
        self.dueToday = dueToday
        self.overdue = overdue
        self.completedToday = completedToday
        self.nextEventTitle = nextEventTitle
        self.nextEventStart = nextEventStart
    }
}

/// Composes the contextual greeting at the top of Home. Pure: depends only on its inputs.
public enum GreetingComposer {
    public static func greeting(now: Date, calendar: Calendar, name: String?, day: DayContext) -> Greeting {
        let hour = calendar.component(.hour, from: now)
        let salutation: String
        switch hour {
        case 5..<12: salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        case 17..<22: salutation = "Good evening"
        default: salutation = "Good night"
        }
        let title = name?.nonBlank.map { "\(salutation), \($0)" } ?? salutation

        var parts: [String] = []
        if day.dueToday > 0 {
            parts.append(day.dueToday == 1 ? "1 task due today" : "\(day.dueToday) tasks due today")
        }
        if day.overdue > 0 {
            parts.append("\(day.overdue) overdue")
        }
        if let event = day.nextEventTitle, let start = day.nextEventStart, start > now {
            let time = TimeOfDay(start, calendar: calendar)
            let isToday = calendar.isDate(start, inSameDayAs: now)
            parts.append(isToday ? "next: \(event) at \(time)" : "next: \(event)")
        }
        let subtitle: String
        if !parts.isEmpty {
            subtitle = parts.joined(separator: " · ")
        } else if day.completedToday > 0 {
            subtitle = day.completedToday == 1 ? "1 task done today. Nothing else is due." : "\(day.completedToday) tasks done today. Nothing else is due."
        } else {
            subtitle = "Nothing is due today."
        }
        return Greeting(title: title, subtitle: subtitle)
    }
}
