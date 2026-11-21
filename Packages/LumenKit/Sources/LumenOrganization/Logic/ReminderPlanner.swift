import Foundation
import LumenFoundation

/// A reminder that should be scheduled.
public struct PlannedReminder: Sendable, Hashable {
    public let entity: EntityReference
    public let fireDate: Date
    public let title: String
    public let body: String
}

/// Turns tasks and events into concrete reminder instants.
public enum ReminderPlanner {
    /// Reminder for a task, or `nil` when it has none, is closed, or the instant has passed.
    public static func reminder(for task: TaskItem, now: Date, calendar: Calendar, defaultTime: TimeOfDay = .nine) -> PlannedReminder? {
        guard task.isOpen, let spec = task.reminder else { return nil }
        let fire: Date?
        switch spec {
        case .at(let date):
            fire = date
        case .atDue:
            fire = task.dueInstant(calendar: calendar, defaultTime: defaultTime)
        case .minutesBefore(let minutes):
            fire = task.dueInstant(calendar: calendar, defaultTime: defaultTime)?.addingTimeInterval(-TimeInterval(minutes * 60))
        }
        guard let fire, fire > now else { return nil }
        return PlannedReminder(entity: task.reference, fireDate: fire, title: task.title, body: dueDescription(for: task))
    }

    /// Reminders for the next occurrences of an event within `horizon` seconds.
    public static func reminders(for occurrences: [EventOccurrence], event: CalendarEvent, now: Date, horizon: TimeInterval) -> [PlannedReminder] {
        let limit = now.addingTimeInterval(horizon)
        return occurrences.flatMap { occurrence -> [PlannedReminder] in
            event.reminderOffsets.compactMap { minutes in
                let fire = occurrence.start.addingTimeInterval(-TimeInterval(max(0, minutes) * 60))
                guard fire > now, fire <= limit else { return nil }
                let body = minutes == 0 ? "Starting now" : "Starts in \(minutes) min"
                return PlannedReminder(entity: event.reference, fireDate: fire, title: event.title, body: body)
            }
        }.sorted { $0.fireDate < $1.fireDate }
    }

    private static func dueDescription(for task: TaskItem) -> String {
        if let time = task.dueTime { return "Due at \(time)" }
        if task.dueDate != nil { return "Due today" }
        return "Reminder"
    }
}
