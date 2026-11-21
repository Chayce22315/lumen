import Foundation
import LumenFoundation

public enum OrganizationError: PresentableError, Equatable {
    case taskNotFound(TaskItem.ID)
    case projectNotFound(Project.ID)
    case calendarNotFound(LumenCalendar.ID)
    case eventNotFound(CalendarEvent.ID)
    case dependencyCycle
    case lastCalendar

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
        }
    }
}
