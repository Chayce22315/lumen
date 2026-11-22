import Foundation
import LumenFoundation

public enum OrganizationError: PresentableError, Equatable {
    case taskNotFound(TaskItem.ID)
    case projectNotFound(Project.ID)
    case calendarNotFound(LumenCalendar.ID)
    case eventNotFound(CalendarEvent.ID)
    case dependencyCycle
    case lastCalendar
    case systemCalendarUnavailable
    case systemCalendarAccessDenied
    case systemCalendarNotFound
    case systemCalendarReadOnly
    case systemEventNotFound

    public var presentation: ErrorPresentation {
        switch self {
        case .taskNotFound:
            return ErrorPresentation(title: "Task not found", message: "This task no longer exists. It may have been deleted on another device.")
        case .projectNotFound:
            return ErrorPresentation(title: "Project not found", message: "This project no longer exists.")
        case .calendarNotFound:
            return ErrorPresentation(title: "Calendar not found", message: "This calendar no longer exists.")
        case .eventNotFound:
            return ErrorPresentation(title: "Event not found", message: "This event no longer exists.")
        case .dependencyCycle:
            return ErrorPresentation(title: "Circular dependency", message: "That would make these tasks wait on each other forever.")
        case .lastCalendar:
            return ErrorPresentation(title: "Keep one calendar", message: "Lumen needs at least one calendar for your events.")
        case .systemCalendarUnavailable:
            return ErrorPresentation(title: "No system calendars", message: "System calendars aren't available here. Save the event in a Lumen calendar instead.")
        case .systemCalendarAccessDenied:
            return ErrorPresentation(
                title: "No calendar access",
                message: "Lumen can't change your calendars. Allow full access in Settings › Privacy & Security › Calendars, or save the event in a Lumen calendar."
            )
        case .systemCalendarNotFound:
            return ErrorPresentation(title: "Calendar not found", message: "That calendar is no longer on this device.")
        case .systemCalendarReadOnly:
            return ErrorPresentation(title: "Read-only calendar", message: "This calendar can't be changed, for example because it is a subscription.")
        case .systemEventNotFound:
            return ErrorPresentation(title: "Event not found", message: "This event is no longer in your calendar. It may have been deleted in another app.")
        }
    }
}
