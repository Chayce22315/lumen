import Foundation
import Observation
import LumenFoundation
import LumenOrganization
import LumenApplication

/// Editing one task. Fields are edited locally and saved together; `hasChanges` drives the
/// Save button and the discard confirmation.
@MainActor
@Observable
public final class TaskEditorViewModel {
    public let taskID: TaskItem.ID
    public private(set) var original: TaskItem?
    public private(set) var state: LoadState<TaskItem> = .idle
    public private(set) var subtasks: [TaskItem] = []
    public private(set) var blockers: [TaskItem] = []
    public private(set) var projects: [Project] = []
    /// Completed focus sessions on this task.
    public private(set) var focusTotals: FocusTotals = .zero
    public private(set) var isSaving = false
    public private(set) var error: ErrorPresentation?

    // Editable fields.
    public var title = ""
    public var notes = ""
    public var priority: TaskPriority = .none
    public var dueDate: CalendarDate?
    public var dueTime: TimeOfDay?
    public var projectID: Project.ID?
    public var tags: [String] = []
    public var recurrence: RecurrenceRule?
    public var reminder: ReminderSpec?
    public var estimatedMinutes: Int?
    public var newSubtaskTitle = ""

    private let services: LumenServices

    public init(taskID: TaskItem.ID, services: LumenServices) {
        self.taskID = taskID
        self.services = services
    }

    public func load() async {
        state = .loading
        do {
            let tasks = services.organization.tasks
            guard let task = try await tasks.task(taskID) else {
                state = .failed(OrganizationError.taskNotFound(taskID).presentation)
                return
            }
            apply(task)
            subtasks = try await tasks.subtasks(of: taskID)
            blockers = try await tasks.tasks(TaskQuery()).filter { task.blockedBy.contains($0.id) }
            projects = try await services.organization.projects.projects(statuses: [.planned, .active, .onHold])
            focusTotals = try await services.focus.service.totals(forTask: taskID)
            state = .loaded(task)
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public var hasChanges: Bool {
        guard let original else { return false }
        return title != original.title || notes != original.notes || priority != original.priority
            || dueDate != original.dueDate || dueTime != original.dueTime || projectID != original.projectID
            || tags != original.tags || recurrence != original.recurrence || reminder != original.reminder
            || estimatedMinutes != original.estimatedMinutes
    }

    /// Saves the edited fields. Returns `true` on success.
    @discardableResult
    public func save() async -> Bool {
        guard let original, hasChanges else { return true }
        isSaving = true
        error = nil
        defer { isSaving = false }
        var changes = TaskChanges()
        if title != original.title { changes.title = title }
        if notes != original.notes { changes.notes = notes }
        if priority != original.priority { changes.priority = priority }
        if dueDate != original.dueDate { changes.dueDate = .some(dueDate) }
        if dueTime != original.dueTime { changes.dueTime = .some(dueDate == nil ? nil : dueTime) }
        if projectID != original.projectID { changes.projectID = .some(projectID) }
        if tags != original.tags { changes.tags = tags }
        if recurrence != original.recurrence { changes.recurrence = .some(recurrence) }
        if reminder != original.reminder { changes.reminder = .some(reminder) }
        if estimatedMinutes != original.estimatedMinutes { changes.estimatedMinutes = .some(estimatedMinutes) }
        do {
            let saved = try await services.organization.tasks.update(taskID, changes)
            apply(saved)
            state = .loaded(saved)
            return true
        } catch {
            self.error = ErrorPresentation.from(error)
            return false
        }
    }

    public func discardChanges() {
        if let original { apply(original) }
    }

    public func toggleCompletion() async {
        guard let original else { return }
        do {
            if original.status == .done {
                apply(try await services.organization.tasks.reopen(taskID))
            } else {
                apply(try await services.organization.tasks.complete(taskID).completed)
            }
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public func addSubtask() async {
        guard let title = newSubtaskTitle.collapsingWhitespace.nonBlank else { return }
        do {
            let created = try await services.organization.tasks.create(TaskDraft(title: title, projectID: projectID, parentID: taskID))
            subtasks.append(created)
            newSubtaskTitle = ""
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public func toggleSubtask(_ id: TaskItem.ID) async {
        guard let index = subtasks.firstIndex(where: { $0.id == id }) else { return }
        do {
            let updated = subtasks[index].status == .done
                ? try await services.organization.tasks.reopen(id)
                : try await services.organization.tasks.complete(id).completed
            subtasks[index] = updated
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public func addBlocker(_ id: TaskItem.ID) async {
        do {
            let updated = try await services.organization.tasks.addDependency(taskID, blockedBy: id)
            if let blocker = try await services.organization.tasks.task(id) { blockers.append(blocker) }
            original = updated
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public func removeBlocker(_ id: TaskItem.ID) async {
        do {
            original = try await services.organization.tasks.removeDependency(taskID, blockedBy: id)
            blockers.removeAll { $0.id == id }
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// "2 sessions · 45 minutes focused"; `nil` before the first completed session.
    public var focusSummary: String? {
        guard focusTotals.sessions > 0 else { return nil }
        let sessions = focusTotals.sessions == 1 ? "1 session" : "\(focusTotals.sessions) sessions"
        return "\(sessions) · \(FocusIntegration.durationText(focusTotals.focusedDuration)) focused"
    }

    /// Deletes the task. Returns `true` when the editor should close.
    public func delete() async -> Bool {
        do {
            try await services.organization.tasks.delete(taskID)
            return true
        } catch {
            self.error = ErrorPresentation.from(error)
            return false
        }
    }

    private func apply(_ task: TaskItem) {
        original = task
        title = task.title
        notes = task.notes
        priority = task.priority
        dueDate = task.dueDate
        dueTime = task.dueTime
        projectID = task.projectID
        tags = task.tags
        recurrence = task.recurrence
        reminder = task.reminder
        estimatedMinutes = task.estimatedMinutes
    }
}
