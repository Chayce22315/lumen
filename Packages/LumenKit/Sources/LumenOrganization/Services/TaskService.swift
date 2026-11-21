import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The result of completing a task.
public struct TaskCompletion: Sendable, Hashable {
    public let completed: TaskItem
    /// The next instance when the task repeats.
    public let nextInstance: TaskItem?
    /// Tasks that became actionable because this was their last open blocker.
    public let unblocked: [TaskItem]
}

/// Counts for the Today header, dashboard widget and assistant context.
public struct TaskSummary: Sendable, Hashable {
    public let dueToday: Int
    public let overdue: Int
    public let completedToday: Int
    public let open: Int

    public init(dueToday: Int, overdue: Int, completedToday: Int, open: Int) {
        self.dueToday = dueToday
        self.overdue = overdue
        self.completedToday = completedToday
        self.open = open
    }
}

/// Tasks: creation, quick capture, editing, completion (with recurrence and dependency
/// unblocking), deletion and every list the interface shows.
public final class TaskService: Sendable {
    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let logger: Logger
    private let tasks = TaskRepository()
    private let projects = ProjectRepository()

    public init(database: Database, events: EventBus, timeSource: any TimeSource, calendar: Calendar, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
    }

    /// Today in the user's calendar.
    public var today: CalendarDate {
        CalendarDate(timeSource.now(), calendar: calendar)
    }

    // MARK: - Creating

    public func create(_ draft: TaskDraft, context: ActionContext = .user) async throws -> TaskItem {
        let now = timeSource.now()
        let candidate = TaskItem(
            title: draft.title,
            notes: draft.notes,
            priority: draft.priority,
            dueDate: draft.dueDate,
            dueTime: draft.dueTime,
            startDate: draft.startDate,
            projectID: draft.projectID,
            parentID: draft.parentID,
            tags: draft.tags,
            recurrence: draft.recurrence,
            recurrenceAnchor: draft.recurrence == nil ? nil : draft.dueDate,
            estimatedMinutes: draft.estimatedMinutes,
            reminder: draft.reminder,
            sortOrder: now.timeIntervalSince1970,
            createdAt: now,
            updatedAt: now
        )
        let task = try TaskValidator.validated(candidate)
        let tasks = self.tasks
        let projects = self.projects
        try await database.write { db in
            if let projectID = task.projectID, try projects.project(projectID, in: db) == nil {
                throw OrganizationError.projectNotFound(projectID)
            }
            if let parentID = task.parentID, try tasks.task(parentID, in: db) == nil {
                throw OrganizationError.taskNotFound(parentID)
            }
            try tasks.save(task, in: db)
        }
        events.publish(context.event(OrganizationEvent.taskCreated, entity: task.reference, attributes: attributes(of: task), at: now))
        return task
    }

    /// Parses a natural-language line, resolves `+project` by name and creates the task.
    public func capture(_ text: String, context: ActionContext = .user) async throws -> (task: TaskItem, parsed: QuickCaptureResult) {
        let parsed = QuickCaptureParser.parse(text, today: today)
        var projectID: Project.ID?
        if let name = parsed.projectName?.foldedForMatching {
            let projects = self.projects
            let all = try await database.read { db in try projects.projects(statuses: nil, in: db) }
            projectID = all.filter(\.status.isLive).first { $0.name.foldedForMatching == name }?.id
                ?? all.first { $0.name.foldedForMatching.hasPrefix(name) && $0.status.isLive }?.id
        }
        let draft = TaskDraft(
            title: parsed.title,
            priority: parsed.priority,
            dueDate: parsed.dueDate,
            dueTime: parsed.dueTime,
            projectID: projectID,
            tags: parsed.tags,
            recurrence: parsed.recurrence
        )
        return (try await create(draft, context: context), parsed)
    }

    // MARK: - Editing

    public func update(_ id: TaskItem.ID, _ changes: TaskChanges, context: ActionContext = .user) async throws -> TaskItem {
        if let status = changes.status {
            switch status {
            case .done: _ = try await complete(id, context: context)
            case .cancelled: _ = try await cancel(id, context: context)
            case .todo, .inProgress: break
            }
        }
        let now = timeSource.now()
        let tasks = self.tasks
        let projects = self.projects
        let updated: TaskItem = try await database.write { db in
            guard let existing = try tasks.task(id, in: db) else { throw OrganizationError.taskNotFound(id) }
            var task = changes.applied(to: existing)
            if let status = changes.status, status == .todo || status == .inProgress {
                task.status = status
                task.completedAt = nil
            }
            // Editing the schedule re-anchors the series at the new due date.
            if task.recurrence != existing.recurrence || task.dueDate != existing.dueDate {
                task.recurrenceAnchor = task.recurrence == nil ? nil : task.dueDate
            }
            task.updatedAt = now
            task = try TaskValidator.validated(task)
            if let projectID = task.projectID, projectID != existing.projectID, try projects.project(projectID, in: db) == nil {
                throw OrganizationError.projectNotFound(projectID)
            }
            try tasks.save(task, in: db)
            return task
        }
        events.publish(context.event(OrganizationEvent.taskUpdated, entity: updated.reference, attributes: attributes(of: updated), at: now))
        return updated
    }

    // MARK: - Status

    public func complete(_ id: TaskItem.ID, context: ActionContext = .user) async throws -> TaskCompletion {
        let now = timeSource.now()
        let today = self.today
        let tasks = self.tasks
        let (completion, changed): (TaskCompletion, Bool) = try await database.write { db in
            guard var task = try tasks.task(id, in: db) else { throw OrganizationError.taskNotFound(id) }
            guard task.status != .done else { return (TaskCompletion(completed: task, nextInstance: nil, unblocked: []), false) }
            task.status = .done
            task.completedAt = now
            task.updatedAt = now
            try tasks.save(task, in: db)

            var next: TaskItem?
            if let instance = RecurringTaskAdvancer.nextInstance(after: task, today: today, now: now) {
                try tasks.save(instance, in: db)
                next = instance
            }

            let dependents = try tasks.dependents(of: id, in: db).filter(\.isOpen)
            var unblocked: [TaskItem] = []
            for dependent in dependents {
                let blockers = try tasks.tasks(dependent.blockedBy, in: db)
                if blockers.allSatisfy({ $0.status.isClosed }) {
                    unblocked.append(dependent)
                }
            }
            return (TaskCompletion(completed: task, nextInstance: next, unblocked: unblocked), true)
        }
        guard changed else { return completion }
        var published = [context.event(OrganizationEvent.taskCompleted, entity: completion.completed.reference, attributes: attributes(of: completion.completed), at: now)]
        if let next = completion.nextInstance {
            published.append(context.event(OrganizationEvent.taskCreated, entity: next.reference, attributes: attributes(of: next), at: now))
        }
        events.publish(published)
        return completion
    }

    public func reopen(_ id: TaskItem.ID, context: ActionContext = .user) async throws -> TaskItem {
        try await transition(id, to: .todo, event: OrganizationEvent.taskReopened, context: context)
    }

    public func cancel(_ id: TaskItem.ID, context: ActionContext = .user) async throws -> TaskItem {
        try await transition(id, to: .cancelled, event: OrganizationEvent.taskCancelled, context: context)
    }

    public func start(_ id: TaskItem.ID, context: ActionContext = .user) async throws -> TaskItem {
        try await transition(id, to: .inProgress, event: OrganizationEvent.taskUpdated, context: context)
    }

    private func transition(_ id: TaskItem.ID, to status: TaskStatus, event name: EventName, context: ActionContext) async throws -> TaskItem {
        let now = timeSource.now()
        let tasks = self.tasks
        let task: TaskItem = try await database.write { db in
            guard var task = try tasks.task(id, in: db) else { throw OrganizationError.taskNotFound(id) }
            task.status = status
            task.completedAt = status == .cancelled ? now : nil
            task.updatedAt = now
            try tasks.save(task, in: db)
            return task
        }
        events.publish(context.event(name, entity: task.reference, attributes: attributes(of: task), at: now))
        return task
    }

    /// Deletes a task, its subtasks, and removes it from other tasks' blockers.
    public func delete(_ id: TaskItem.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let tasks = self.tasks
        let deleted: [TaskItem.ID] = try await database.write { db in
            guard try tasks.task(id, in: db) != nil else { throw OrganizationError.taskNotFound(id) }
            var toDelete: [TaskItem.ID] = []
            var frontier = [id]
            while let current = frontier.popLast() {
                toDelete.append(current)
                frontier.append(contentsOf: try tasks.tasks(matching: TaskQuery(parentID: .some(current)), in: db).map(\.id))
            }
            let deletedSet = Set(toDelete)
            for removed in toDelete {
                for var dependent in try tasks.dependents(of: removed, in: db) where !deletedSet.contains(dependent.id) {
                    dependent.blockedBy.removeAll { $0 == removed }
                    dependent.updatedAt = now
                    try tasks.save(dependent, in: db)
                }
            }
            for removed in toDelete {
                try tasks.delete(removed, in: db)
            }
            return toDelete
        }
        events.publish(deleted.map { context.event(OrganizationEvent.taskDeleted, entity: EntityReference(kind: .task, id: $0), at: now) })
    }

    // MARK: - Dependencies and order

    public func addDependency(_ id: TaskItem.ID, blockedBy blocker: TaskItem.ID, context: ActionContext = .user) async throws -> TaskItem {
        let now = timeSource.now()
        let tasks = self.tasks
        let task: TaskItem = try await database.write { db in
            guard var task = try tasks.task(id, in: db) else { throw OrganizationError.taskNotFound(id) }
            guard try tasks.task(blocker, in: db) != nil else { throw OrganizationError.taskNotFound(blocker) }
            guard !task.blockedBy.contains(blocker) else { return task }
            let graph = DependencyGraph(tasks: try tasks.all(in: db))
            guard !graph.wouldCreateCycle(task: id, blockedBy: blocker) else { throw OrganizationError.dependencyCycle }
            task.blockedBy.append(blocker)
            task.updatedAt = now
            try tasks.save(task, in: db)
            return task
        }
        events.publish(context.event(OrganizationEvent.taskUpdated, entity: task.reference, attributes: attributes(of: task), at: now))
        return task
    }

    public func removeDependency(_ id: TaskItem.ID, blockedBy blocker: TaskItem.ID, context: ActionContext = .user) async throws -> TaskItem {
        let now = timeSource.now()
        let tasks = self.tasks
        let task: TaskItem = try await database.write { db in
            guard var task = try tasks.task(id, in: db) else { throw OrganizationError.taskNotFound(id) }
            task.blockedBy.removeAll { $0 == blocker }
            task.updatedAt = now
            try tasks.save(task, in: db)
            return task
        }
        events.publish(context.event(OrganizationEvent.taskUpdated, entity: task.reference, attributes: attributes(of: task), at: now))
        return task
    }

    /// Persists a manual order: `ids` are given consecutive sort orders.
    public func reorder(_ ids: [TaskItem.ID], context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let tasks = self.tasks
        let changed: [TaskItem] = try await database.write { db in
            var changed: [TaskItem] = []
            for (index, id) in ids.enumerated() {
                guard var task = try tasks.task(id, in: db) else { continue }
                let order = Double(index)
                guard task.sortOrder != order else { continue }
                task.sortOrder = order
                task.updatedAt = now
                try tasks.save(task, in: db)
                changed.append(task)
            }
            return changed
        }
        events.publish(changed.map { context.event(OrganizationEvent.taskUpdated, entity: $0.reference, attributes: attributes(of: $0), at: now) })
    }

    // MARK: - Reading

    public func task(_ id: TaskItem.ID) async throws -> TaskItem? {
        let tasks = self.tasks
        return try await database.read { db in try tasks.task(id, in: db) }
    }

    public func tasks(_ query: TaskQuery) async throws -> [TaskItem] {
        let tasks = self.tasks
        return try await database.read { db in try tasks.tasks(matching: query, in: db) }.sorted(by: TaskOrdering.actionableFirst)
    }

    public func list(_ list: SmartList, limit: Int? = nil) async throws -> [TaskItem] {
        let tasks = self.tasks
        let today = self.today
        let candidates: [TaskItem] = try await database.read { db in
            switch list {
            case .completed:
                return try tasks.tasks(matching: TaskQuery(statuses: [.done, .cancelled]), in: db)
            default:
                return try tasks.tasks(matching: .open, in: db)
            }
        }
        let ordered = TaskOrdering.list(list, from: candidates, today: today)
        guard let limit else { return ordered }
        return Array(ordered.prefix(max(0, limit)))
    }

    public func subtasks(of id: TaskItem.ID) async throws -> [TaskItem] {
        try await tasks(TaskQuery(parentID: .some(id)))
    }

    /// Identifiers of open tasks that are waiting on an open blocker.
    public func blockedTaskIDs() async throws -> Set<TaskItem.ID> {
        let tasks = self.tasks
        let all = try await database.read { db in try tasks.all(in: db) }
        let statuses = Dictionary(all.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let graph = DependencyGraph(tasks: all)
        return Set(all.filter { $0.isOpen && graph.isBlocked($0.id, statuses: statuses) }.map(\.id))
    }

    public func allTasks() async throws -> [TaskItem] {
        let tasks = self.tasks
        return try await database.read { db in try tasks.all(in: db) }
    }

    public func summary() async throws -> TaskSummary {
        let tasks = self.tasks
        let today = self.today
        let start = today.startDate(in: calendar)
        let end = today.adding(days: 1).startDate(in: calendar)
        return try await database.read { db in
            let open = try tasks.tasks(matching: .open, in: db)
            let completedToday = try tasks.completed(between: start, and: end, in: db).count
            return TaskSummary(
                dueToday: open.filter { $0.dueDate == today }.count,
                overdue: open.filter { $0.isOverdue(today: today) }.count,
                completedToday: completedToday,
                open: open.count
            )
        }
    }

    /// Completed tasks in `[start, end)`, newest first.
    public func completed(from start: Date, to end: Date) async throws -> [TaskItem] {
        let tasks = self.tasks
        return try await database.read { db in try tasks.completed(between: start, and: end, in: db) }
    }

    private func attributes(of task: TaskItem) -> [String: JSONValue] {
        var attributes: [String: JSONValue] = [
            "status": .string(task.status.rawValue),
            "priority": .number(Double(task.priority.rawValue)),
        ]
        if let projectID = task.projectID { attributes["projectID"] = .string(projectID.uuidString) }
        if let due = task.dueDate { attributes["dueDate"] = .string(due.description) }
        if !task.tags.isEmpty { attributes["tags"] = .array(task.tags.map(JSONValue.string)) }
        return attributes
    }
}
