import Foundation
import LumenFoundation
import LumenCore

extension EntityKind {
    public static let task: EntityKind = "task"
    public static let project: EntityKind = "project"
    public static let calendarEvent: EntityKind = "calendar-event"
    public static let calendar: EntityKind = "calendar"
}

/// Event names published by the organization engine. Persisted by analytics and referenced by
/// saved automations — never rename.
public enum OrganizationEvent {
    public static let taskCreated: EventName = "organization.task.created"
    public static let taskUpdated: EventName = "organization.task.updated"
    public static let taskCompleted: EventName = "organization.task.completed"
    public static let taskReopened: EventName = "organization.task.reopened"
    public static let taskCancelled: EventName = "organization.task.cancelled"
    public static let taskDeleted: EventName = "organization.task.deleted"

    public static let projectCreated: EventName = "organization.project.created"
    public static let projectUpdated: EventName = "organization.project.updated"
    public static let projectCompleted: EventName = "organization.project.completed"
    public static let projectDeleted: EventName = "organization.project.deleted"

    public static let eventCreated: EventName = "organization.event.created"
    public static let eventUpdated: EventName = "organization.event.updated"
    public static let eventDeleted: EventName = "organization.event.deleted"

    public static let calendarCreated: EventName = "organization.calendar.created"
    public static let calendarUpdated: EventName = "organization.calendar.updated"
    public static let calendarDeleted: EventName = "organization.calendar.deleted"

    public static let all: [EventName] = [
        taskCreated, taskUpdated, taskCompleted, taskReopened, taskCancelled, taskDeleted,
        projectCreated, projectUpdated, projectCompleted, projectDeleted,
        eventCreated, eventUpdated, eventDeleted,
        calendarCreated, calendarUpdated, calendarDeleted,
    ]
}
