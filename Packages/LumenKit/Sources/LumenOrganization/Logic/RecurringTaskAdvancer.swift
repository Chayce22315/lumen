import Foundation
import LumenFoundation

/// Computes the next instance of a recurring task when one is completed.
///
/// The completed task keeps its history; a new open task carries the series forward. If the
/// completed instance was overdue by several periods, the next instance lands on the first
/// occurrence after today instead of producing a backlog of already-missed copies (missed
/// occurrences still count toward an `afterOccurrences` limit).
public enum RecurringTaskAdvancer {
    public static func nextInstance(
        after completed: TaskItem,
        today: CalendarDate,
        now: Date,
        newID: TaskItem.ID = TaskItem.ID()
    ) -> TaskItem? {
        guard let rule = completed.recurrence, let due = completed.dueDate else { return nil }
        let anchor = completed.recurrenceAnchor ?? due
        let floor = max(due, today)
        guard let nextDue = RecurrenceCalculator.occurrences(of: rule, anchor: anchor, after: floor, limit: 1).first else {
            return nil
        }
        let shift = nextDue.days(since: due)
        return TaskItem(
            id: newID,
            title: completed.title,
            notes: completed.notes,
            status: .todo,
            priority: completed.priority,
            dueDate: nextDue,
            dueTime: completed.dueTime,
            startDate: completed.startDate.map { $0.adding(days: shift) },
            projectID: completed.projectID,
            parentID: completed.parentID,
            tags: completed.tags,
            recurrence: rule,
            recurrenceAnchor: anchor,
            seriesID: completed.seriesID ?? completed.id.rawValue,
            blockedBy: [],
            estimatedMinutes: completed.estimatedMinutes,
            reminder: completed.reminder.map { reminder in
                if case .at(let date) = reminder {
                    return .at(date.addingTimeInterval(TimeInterval(shift) * 86_400))
                }
                return reminder
            },
            sortOrder: completed.sortOrder,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
    }
}
