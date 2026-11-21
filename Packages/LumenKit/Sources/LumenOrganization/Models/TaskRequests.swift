import Foundation
import LumenFoundation

/// Input for creating a task.
public struct TaskDraft: Sendable, Hashable {
    public var title: String
    public var notes: String
    public var priority: TaskPriority
    public var dueDate: CalendarDate?
    public var dueTime: TimeOfDay?
    public var startDate: CalendarDate?
    public var projectID: Project.ID?
    public var parentID: TaskItem.ID?
    public var tags: [String]
    public var recurrence: RecurrenceRule?
    public var estimatedMinutes: Int?
    public var reminder: ReminderSpec?

    public init(
        title: String,
        notes: String = "",
        priority: TaskPriority = .none,
        dueDate: CalendarDate? = nil,
        dueTime: TimeOfDay? = nil,
        startDate: CalendarDate? = nil,
        projectID: Project.ID? = nil,
        parentID: TaskItem.ID? = nil,
        tags: [String] = [],
        recurrence: RecurrenceRule? = nil,
        estimatedMinutes: Int? = nil,
        reminder: ReminderSpec? = nil
    ) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.startDate = startDate
        self.projectID = projectID
        self.parentID = parentID
        self.tags = tags
        self.recurrence = recurrence
        self.estimatedMinutes = estimatedMinutes
        self.reminder = reminder
    }
}

/// A partial update. `nil` leaves a field unchanged; `.some(nil)` clears an optional field.
public struct TaskChanges: Sendable, Hashable {
    public var title: String?
    public var notes: String?
    public var priority: TaskPriority?
    public var status: TaskStatus?
    public var dueDate: CalendarDate??
    public var dueTime: TimeOfDay??
    public var startDate: CalendarDate??
    public var projectID: Project.ID??
    public var tags: [String]?
    public var recurrence: RecurrenceRule??
    public var estimatedMinutes: Int??
    public var reminder: ReminderSpec??

    public init(
        title: String? = nil,
        notes: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        dueDate: CalendarDate?? = nil,
        dueTime: TimeOfDay?? = nil,
        startDate: CalendarDate?? = nil,
        projectID: Project.ID?? = nil,
        tags: [String]? = nil,
        recurrence: RecurrenceRule?? = nil,
        estimatedMinutes: Int?? = nil,
        reminder: ReminderSpec?? = nil
    ) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.status = status
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.startDate = startDate
        self.projectID = projectID
        self.tags = tags
        self.recurrence = recurrence
        self.estimatedMinutes = estimatedMinutes
        self.reminder = reminder
    }

    /// Applies the changes to `task` (status transitions are handled by `TaskService`).
    func applied(to task: TaskItem) -> TaskItem {
        var result = task
        if let title { result.title = title }
        if let notes { result.notes = notes }
        if let priority { result.priority = priority }
        if let dueDate { result.dueDate = dueDate }
        if let dueTime { result.dueTime = dueTime }
        if let startDate { result.startDate = startDate }
        if let projectID { result.projectID = projectID }
        if let tags { result.tags = tags }
        if let recurrence { result.recurrence = recurrence }
        if let estimatedMinutes { result.estimatedMinutes = estimatedMinutes }
        if let reminder { result.reminder = reminder }
        return result
    }
}

/// Built-in task lists.
public enum SmartList: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Due or started on or before today, open.
    case today
    /// Due within the next seven days (after today).
    case upcoming
    /// Open, due before today.
    case overdue
    /// Open, no project, no due date.
    case inbox
    /// Open, not deferred to the future.
    case anytime
    /// Closed tasks, most recent first.
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .overdue: return "Overdue"
        case .inbox: return "Inbox"
        case .anytime: return "Anytime"
        case .completed: return "Completed"
        }
    }
}

/// Free-form task filtering.
public struct TaskQuery: Sendable, Hashable {
    public var statuses: Set<TaskStatus>?
    public var projectID: Project.ID??
    public var parentID: TaskItem.ID??
    public var tag: String?
    public var dueOnOrBefore: CalendarDate?
    public var dueOnOrAfter: CalendarDate?
    public var minimumPriority: TaskPriority?
    public var limit: Int?

    public init(
        statuses: Set<TaskStatus>? = nil,
        projectID: Project.ID?? = nil,
        parentID: TaskItem.ID?? = nil,
        tag: String? = nil,
        dueOnOrBefore: CalendarDate? = nil,
        dueOnOrAfter: CalendarDate? = nil,
        minimumPriority: TaskPriority? = nil,
        limit: Int? = nil
    ) {
        self.statuses = statuses
        self.projectID = projectID
        self.parentID = parentID
        self.tag = tag
        self.dueOnOrBefore = dueOnOrBefore
        self.dueOnOrAfter = dueOnOrAfter
        self.minimumPriority = minimumPriority
        self.limit = limit
    }

    public static let open = TaskQuery(statuses: [.todo, .inProgress])
}
