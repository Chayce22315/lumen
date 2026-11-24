import Foundation
import LumenFoundation

/// Ordering and smart-list membership rules. Pure so the interface, widgets and the assistant all
/// agree on what "Today" means.
public enum TaskOrdering {
    /// Most actionable first: overdue and due-soon before later, higher priority first within a
    /// day, tasks with a time before untimed ones, then manual order, then creation.
    public static func actionableFirst(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (l?, r?) where l != r: return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        switch (lhs.dueTime, rhs.dueTime) {
        case let (l?, r?) where l != r: return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    /// Whether `task` belongs in `list` on `today`.
    public static func belongs(_ task: TaskItem, to list: SmartList, today: CalendarDate) -> Bool {
        switch list {
        case .today:
            guard task.isOpen else { return false }
            if let due = task.dueDate, due <= today { return true }
            if let start = task.startDate, start <= today, task.dueDate == nil { return true }
            return false
        case .upcoming:
            guard task.isOpen, let due = task.dueDate else { return false }
            return due > today && due <= today.adding(days: 7)
        case .overdue:
            return task.isOverdue(today: today)
        case .inbox:
            return task.isOpen && task.projectID == nil && task.dueDate == nil && task.parentID == nil
        case .anytime:
            guard task.isOpen else { return false }
            if let start = task.startDate, start > today { return false }
            return true
        case .completed:
            return task.status.isClosed
        }
    }

    /// Tasks of `list`, ordered for display.
    public static func list(_ list: SmartList, from tasks: [TaskItem], today: CalendarDate) -> [TaskItem] {
        let members = tasks.filter { belongs($0, to: list, today: today) }
        if list == .completed {
            return members.sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        }
        return members.sorted(by: actionableFirst)
    }
}
