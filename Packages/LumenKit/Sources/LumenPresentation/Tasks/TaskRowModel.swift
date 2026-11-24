import Foundation
import LumenFoundation
import LumenOrganization

/// What a task row displays, precomputed so rows stay cheap to render.
public struct TaskRowModel: Sendable, Hashable, Identifiable {
    public let task: TaskItem
    public let isBlocked: Bool
    public let projectName: String?
    public let projectColor: ProjectColor?
    public let dueLabel: String?
    public let isOverdue: Bool
    public let subtaskSummary: String?

    public var id: TaskItem.ID { task.id }
    public var isDone: Bool { task.status == .done }

    /// Spoken by VoiceOver: title, then the facts that matter.
    public var accessibilityLabel: String {
        var parts = [task.title]
        if isDone { parts.append("completed") }
        if isOverdue, let dueLabel { parts.append("overdue, due \(dueLabel)") } else if let dueLabel { parts.append("due \(dueLabel)") }
        if task.priority >= .high { parts.append("\(task.priority.title.lowercased()) priority") }
        if isBlocked { parts.append("waiting on another task") }
        if let projectName { parts.append("in \(projectName)") }
        return parts.joined(separator: ", ")
    }
}

enum TaskRowBuilder {
    static func rows(
        _ tasks: [TaskItem],
        blocked: Set<TaskItem.ID>,
        projects: [Project.ID: Project],
        subtasks: [TaskItem.ID: [TaskItem]],
        today: CalendarDate,
        labels: DateLabels
    ) -> [TaskRowModel] {
        tasks.map { task in
            let project = task.projectID.flatMap { projects[$0] }
            let children = subtasks[task.id] ?? []
            return TaskRowModel(
                task: task,
                isBlocked: blocked.contains(task.id),
                projectName: project?.name,
                projectColor: project?.color,
                dueLabel: task.dueDate.map { labels.dueLabel(day: $0, time: task.dueTime, today: today) },
                isOverdue: task.isOverdue(today: today),
                subtaskSummary: children.isEmpty ? nil : "\(children.filter { $0.status == .done }.count)/\(children.count)"
            )
        }
    }
}
