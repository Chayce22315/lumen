import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// Which tasks a list shows.
public enum TaskListSource: Sendable, Hashable {
    case smart(SmartList)
    case project(Project.ID)
    case tag(String)
}

/// A task list with optimistic completion: the row updates immediately and rolls back if
/// saving fails.
@MainActor
@Observable
public final class TaskListViewModel {
    public let source: TaskListSource
    public private(set) var state: LoadState<[TaskRowModel]> = .idle
    public private(set) var title: String
    /// Rows completed while this list is open stay in place (checked) until the list is left, so
    /// the checkmark animation can finish and a mistaken tap can be undone with another tap.
    public private(set) var recentlyCompleted: Set<TaskItem.ID> = []

    private let services: LumenServices
    private let labels: DateLabels
    private let observation = ObservationHandle()

    public init(source: TaskListSource, services: LumenServices, locale: Locale = .current) {
        self.source = source
        self.services = services
        self.labels = DateLabels(calendar: services.calendar, locale: locale)
        switch source {
        case .smart(let list): title = list.title
        case .project: title = "Project"
        case .tag(let tag): title = "#\(tag)"
        }
    }

    public var rows: [TaskRowModel] { state.value ?? [] }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .project]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            let tasks = services.organization.tasks
            let today = services.today
            let listed: [TaskItem]
            switch source {
            case .smart(let list):
                listed = try await tasks.list(list)
            case .project(let id):
                if let project = try await services.organization.projects.project(id) { title = project.name }
                listed = try await tasks.tasks(TaskQuery(projectID: .some(id), parentID: .some(nil)))
                    .filter { $0.isOpen || recentlyCompleted.contains($0.id) || $0.status == .done }
            case .tag(let tag):
                listed = try await tasks.tasks(TaskQuery(statuses: [.todo, .inProgress], tag: tag))
            }
            let visible = try await keepingRecentlyCompleted(listed)
            let projects = Dictionary(try await services.organization.projects.projects().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let all = try await tasks.allTasks()
            let subtasks = Dictionary(grouping: all.filter { $0.parentID != nil }, by: { $0.parentID ?? $0.id })
            let blocked = try await tasks.blockedTaskIDs()
            state = .loaded(TaskRowBuilder.rows(visible, blocked: blocked, projects: projects, subtasks: subtasks, today: today, labels: labels))
        } catch {
            if state.value == nil {
                state = .failed(ErrorPresentation.from(error))
            } else {
                services.errors.report(error, context: "Refreshing tasks")
            }
        }
    }

    /// Adds back tasks completed while the list is open that the query no longer returns (smart
    /// lists and tags only return open tasks), at the position they had.
    private func keepingRecentlyCompleted(_ listed: [TaskItem]) async throws -> [TaskItem] {
        let present = Set(listed.map(\.id))
        let previous = rows.map(\.id)
        let missing = recentlyCompleted
            .filter { !present.contains($0) }
            .sorted { (previous.firstIndex(of: $0) ?? .max) < (previous.firstIndex(of: $1) ?? .max) }
        guard !missing.isEmpty else { return listed }
        var result = listed
        for id in missing {
            guard let task = try await services.organization.tasks.task(id), task.status.isClosed else { continue }
            let position = previous.firstIndex(of: id).map { min($0, result.count) } ?? result.count
            result.insert(task, at: position)
        }
        return result
    }

    /// Toggles done/open, updating the row before the write lands.
    public func toggleCompletion(_ id: TaskItem.ID) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let original = rows
        let row = original[index]
        var optimistic = row.task
        optimistic.status = row.isDone ? .todo : .done
        replaceRow(at: index, with: optimistic, from: row)
        do {
            if row.isDone {
                _ = try await services.organization.tasks.reopen(id)
                recentlyCompleted.remove(id)
            } else {
                recentlyCompleted.insert(id)
                _ = try await services.organization.tasks.complete(id)
            }
        } catch {
            state = .loaded(original)
            recentlyCompleted.remove(id)
            services.errors.report(error, context: "Updating a task")
        }
    }

    public func delete(_ id: TaskItem.ID) async {
        let original = rows
        state = .loaded(original.filter { $0.id != id })
        do {
            try await services.organization.tasks.delete(id)
        } catch {
            state = .loaded(original)
            services.errors.report(error, context: "Deleting a task")
        }
    }

    public func reschedule(_ id: TaskItem.ID, to day: CalendarDate?) async {
        do {
            _ = try await services.organization.tasks.update(id, TaskChanges(dueDate: .some(day)))
        } catch {
            services.errors.report(error, context: "Rescheduling a task")
        }
    }

    /// Persists a manual order after drag-and-drop.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var reordered = rows
        let moving = source.sorted().map { reordered[$0] }
        let base = destination - source.filter { $0 < destination }.count
        reordered.removeAll { row in moving.contains(row) }
        reordered.insert(contentsOf: moving, at: min(max(base, 0), reordered.count))
        state = .loaded(reordered)
        do {
            try await services.organization.tasks.reorder(reordered.map(\.id))
        } catch {
            services.errors.report(error, context: "Reordering tasks")
            await load()
        }
    }

    private func replaceRow(at index: Int, with task: TaskItem, from row: TaskRowModel) {
        var updated = rows
        updated[index] = TaskRowModel(
            task: task,
            isBlocked: row.isBlocked,
            projectName: row.projectName,
            projectColor: row.projectColor,
            dueLabel: row.dueLabel,
            isOverdue: task.isOpen && row.isOverdue,
            subtaskSummary: row.subtaskSummary
        )
        state = .loaded(updated)
    }
}
