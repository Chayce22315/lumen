import Foundation
import LumenFoundation

public enum TaskStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case todo
    case inProgress
    case done
    case cancelled

    /// Done or cancelled: no longer actionable.
    public var isClosed: Bool { self == .done || self == .cancelled }
}

public enum TaskPriority: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case urgent = 4

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }
}

/// When to be reminded about a task or event.
public enum ReminderSpec: Sendable, Codable, Hashable {
    /// At the due time (or at the default reminder time for all-day tasks).
    case atDue
    /// A number of minutes before the due time.
    case minutesBefore(Int)
    /// An absolute instant.
    case at(Date)
}

/// A task. Tasks can belong to a project, have subtasks (via `parentID`), depend on other tasks,
/// recur, and carry an optional reminder.
public struct TaskItem: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<TaskItem>

    public let id: ID
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var priority: TaskPriority
    /// The day the task is due.
    public var dueDate: CalendarDate?
    /// Optional time on `dueDate`; `nil` means "any time that day".
    public var dueTime: TimeOfDay?
    /// Hidden from Today until this day ("defer until").
    public var startDate: CalendarDate?
    public var projectID: Project.ID?
    public var parentID: ID?
    public var tags: [String]
    public var recurrence: RecurrenceRule?
    /// First due date of the recurring series. Occurrences are computed from it (not from the
    /// current instance), so clamped dates (31st → 30th, 29 Feb → 28 Feb) never drift and
    /// count-limited series count correctly.
    public var recurrenceAnchor: CalendarDate?
    /// Identifies all instances of one recurring series.
    public var seriesID: UUID?
    /// Tasks that must be closed before this one is actionable.
    public var blockedBy: [ID]
    public var estimatedMinutes: Int?
    public var reminder: ReminderSpec?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: ID = ID(),
        title: String,
        notes: String = "",
        status: TaskStatus = .todo,
        priority: TaskPriority = .none,
        dueDate: CalendarDate? = nil,
        dueTime: TimeOfDay? = nil,
        startDate: CalendarDate? = nil,
        projectID: Project.ID? = nil,
        parentID: ID? = nil,
        tags: [String] = [],
        recurrence: RecurrenceRule? = nil,
        recurrenceAnchor: CalendarDate? = nil,
        seriesID: UUID? = nil,
        blockedBy: [ID] = [],
        estimatedMinutes: Int? = nil,
        reminder: ReminderSpec? = nil,
        sortOrder: Double = 0,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.startDate = startDate
        self.projectID = projectID
        self.parentID = parentID
        self.tags = tags
        self.recurrence = recurrence
        self.recurrenceAnchor = recurrenceAnchor
        self.seriesID = seriesID
        self.blockedBy = blockedBy
        self.estimatedMinutes = estimatedMinutes
        self.reminder = reminder
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public var isOpen: Bool { !status.isClosed }

    public var reference: EntityReference { EntityReference(kind: .task, id: id) }

    /// Overdue when open and due strictly before `today`.
    public func isOverdue(today: CalendarDate) -> Bool {
        guard isOpen, let dueDate else { return false }
        return dueDate < today
    }

    /// The instant the task is due, using `defaultTime` for tasks without a time.
    public func dueInstant(calendar: Calendar, defaultTime: TimeOfDay = .nine) -> Date? {
        guard let dueDate else { return nil }
        return (dueTime ?? defaultTime).date(on: dueDate, calendar: calendar)
    }
}

// Decoding with defaults keeps older change-log snapshots readable as fields are added.
extension TaskItem {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, status, priority, dueDate, dueTime, startDate, projectID, parentID, tags
        case recurrence, recurrenceAnchor, seriesID, blockedBy, estimatedMinutes, reminder, sortOrder, createdAt, updatedAt, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .todo
        self.priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? TaskPriority.none
        self.dueDate = try c.decodeIfPresent(CalendarDate.self, forKey: .dueDate)
        self.dueTime = try c.decodeIfPresent(TimeOfDay.self, forKey: .dueTime)
        self.startDate = try c.decodeIfPresent(CalendarDate.self, forKey: .startDate)
        self.projectID = try c.decodeIfPresent(Project.ID.self, forKey: .projectID)
        self.parentID = try c.decodeIfPresent(ID.self, forKey: .parentID)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.recurrence = try c.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        self.recurrenceAnchor = try c.decodeIfPresent(CalendarDate.self, forKey: .recurrenceAnchor)
        self.seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        self.blockedBy = try c.decodeIfPresent([ID].self, forKey: .blockedBy) ?? []
        self.estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        self.reminder = try c.decodeIfPresent(ReminderSpec.self, forKey: .reminder)
        self.sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}
