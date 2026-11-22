import Foundation
import LumenFoundation
import LumenPersistence
import LumenOrganization
import LumenSearch
import LumenSync

/// Organization's adapters for search and sync.
enum OrganizationIntegration {
    static func syncHandlers() -> [any SyncEntityHandler] {
        let tasks = TaskRepository()
        let projects = ProjectRepository()
        let calendars = CalendarRepository()
        return [
            CodableSyncHandler<TaskItem>(
                kind: .task,
                fetch: { id, db in try tasks.task(TaskItem.ID(id), in: db) },
                upsert: { task, db in try tasks.upsertRow(task, in: db) },
                delete: { id, db in try tasks.deleteRow(TaskItem.ID(id), in: db) }
            ),
            CodableSyncHandler<Project>(
                kind: .project,
                fetch: { id, db in try projects.project(Project.ID(id), in: db) },
                upsert: { project, db in try projects.upsertRow(project, in: db) },
                delete: { id, db in try projects.deleteRow(Project.ID(id), in: db) }
            ),
            CodableSyncHandler<LumenCalendar>(
                kind: .calendar,
                fetch: { id, db in try calendars.calendar(LumenCalendar.ID(id), in: db) },
                upsert: { calendar, db in try calendars.upsertRow(calendar, in: db) },
                delete: { id, db in try calendars.deleteRow(LumenCalendar.ID(id), in: db) }
            ),
            CodableSyncHandler<CalendarEvent>(
                kind: .calendarEvent,
                fetch: { id, db in try calendars.event(CalendarEvent.ID(id), in: db) },
                upsert: { event, db in try calendars.upsertRow(event, in: db) },
                delete: { id, db in try calendars.deleteRow(CalendarEvent.ID(id), in: db) }
            ),
        ]
    }
}

struct TaskSearchSource: SearchableSource {
    let tasks: TaskService
    let projects: ProjectService

    var kind: EntityKind { .task }

    func document(for id: UUID) async throws -> SearchDocument? {
        guard let task = try await tasks.task(TaskItem.ID(id)) else { return nil }
        let projectName = try await task.projectID.asyncMap { try await projects.project($0)?.name } ?? nil
        return Self.document(for: task, projectName: projectName)
    }

    func allDocuments() async throws -> [SearchDocument] {
        let names = Dictionary(try await projects.projects().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return try await tasks.allTasks().map { Self.document(for: $0, projectName: $0.projectID.flatMap { names[$0] }) }
    }

    static func document(for task: TaskItem, projectName: String?) -> SearchDocument {
        var subtitle: [String] = []
        if let projectName { subtitle.append(projectName) }
        if let due = task.dueDate { subtitle.append("Due \(due)") }
        if task.status.isClosed { subtitle.append(task.status == .done ? "Done" : "Cancelled") }
        return SearchDocument(
            reference: task.reference,
            title: task.title,
            subtitle: subtitle.joined(separator: " · "),
            body: task.notes,
            tags: task.tags,
            updatedAt: task.updatedAt,
            boost: task.isOpen ? 1.2 : 0.6
        )
    }
}

struct ProjectSearchSource: SearchableSource {
    let projects: ProjectService

    var kind: EntityKind { .project }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await projects.project(Project.ID(id)).map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await projects.projects().map(Self.document(for:))
    }

    static func document(for project: Project) -> SearchDocument {
        SearchDocument(
            reference: project.reference,
            title: project.name,
            subtitle: "Project · \(project.status.title)",
            body: project.summary,
            updatedAt: project.updatedAt,
            boost: project.status.isLive ? 1.3 : 0.6
        )
    }
}

struct EventSearchSource: SearchableSource {
    let calendars: CalendarService

    var kind: EntityKind { .calendarEvent }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await calendars.event(CalendarEvent.ID(id)).map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await calendars.allEvents().map(Self.document(for:))
    }

    static func document(for event: CalendarEvent) -> SearchDocument {
        let subtitle: String
        switch event.timing {
        case .allDay(let start, let end):
            subtitle = start == end ? "Event · \(start)" : "Event · \(start) – \(end)"
        case .timed(let start, _, _):
            subtitle = "Event · \(ISO8601DateFormatter().string(from: start))"
        }
        return SearchDocument(
            reference: event.reference,
            title: event.title,
            subtitle: [subtitle, event.location].filter { !$0.isEmpty }.joined(separator: " · "),
            body: event.notes,
            updatedAt: event.updatedAt
        )
    }
}

extension Optional {
    /// `map` for an async transform.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
