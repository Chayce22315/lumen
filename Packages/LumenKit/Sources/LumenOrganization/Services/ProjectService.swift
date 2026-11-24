import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

public struct ProjectChanges: Sendable, Hashable {
    public var name: String?
    public var summary: String?
    public var color: ProjectColor?
    public var startDate: CalendarDate??
    public var targetDate: CalendarDate??

    public init(name: String? = nil, summary: String? = nil, color: ProjectColor? = nil, startDate: CalendarDate?? = nil, targetDate: CalendarDate?? = nil) {
        self.name = name
        self.summary = summary
        self.color = color
        self.startDate = startDate
        self.targetDate = targetDate
    }
}

/// Projects: lifecycle, progress and health.
public final class ProjectService: Sendable {
    public static let maximumNameLength = 200

    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let logger: Logger
    private let projects = ProjectRepository()
    private let tasks = TaskRepository()

    public init(database: Database, events: EventBus, timeSource: any TimeSource, calendar: Calendar, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
    }

    public func create(
        name: String,
        summary: String = "",
        color: ProjectColor = .blue,
        startDate: CalendarDate? = nil,
        targetDate: CalendarDate? = nil,
        context: ActionContext = .user
    ) async throws -> Project {
        let now = timeSource.now()
        let project = try validated(Project(
            name: name,
            summary: summary,
            status: .active,
            color: color,
            startDate: startDate,
            targetDate: targetDate,
            sortOrder: now.timeIntervalSince1970,
            createdAt: now,
            updatedAt: now
        ))
        let projects = self.projects
        try await database.write { db in try projects.save(project, in: db) }
        events.publish(context.event(OrganizationEvent.projectCreated, entity: project.reference, attributes: ["status": .string(project.status.rawValue)], at: now))
        return project
    }

    public func update(_ id: Project.ID, _ changes: ProjectChanges, context: ActionContext = .user) async throws -> Project {
        let now = timeSource.now()
        let projects = self.projects
        let project: Project = try await database.write { db in
            guard var project = try projects.project(id, in: db) else { throw OrganizationError.projectNotFound(id) }
            if let name = changes.name { project.name = name }
            if let summary = changes.summary { project.summary = summary }
            if let color = changes.color { project.color = color }
            if let startDate = changes.startDate { project.startDate = startDate }
            if let targetDate = changes.targetDate { project.targetDate = targetDate }
            project.updatedAt = now
            project = try Self.validate(project)
            try projects.save(project, in: db)
            return project
        }
        events.publish(context.event(OrganizationEvent.projectUpdated, entity: project.reference, attributes: ["status": .string(project.status.rawValue)], at: now))
        return project
    }

    public func setStatus(_ id: Project.ID, _ status: ProjectStatus, context: ActionContext = .user) async throws -> Project {
        let now = timeSource.now()
        let projects = self.projects
        let project: Project = try await database.write { db in
            guard var project = try projects.project(id, in: db) else { throw OrganizationError.projectNotFound(id) }
            project.status = status
            project.completedAt = status == .completed ? now : (status == .archived ? project.completedAt : nil)
            project.updatedAt = now
            try projects.save(project, in: db)
            return project
        }
        let name = status == .completed ? OrganizationEvent.projectCompleted : OrganizationEvent.projectUpdated
        events.publish(context.event(name, entity: project.reference, attributes: ["status": .string(status.rawValue)], at: now))
        return project
    }

    /// Deletes a project. Its tasks are either deleted too or moved out of the project.
    public func delete(_ id: Project.ID, deletingTasks: Bool, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let projects = self.projects
        let tasks = self.tasks
        let affected: [TaskItem] = try await database.write { db in
            guard try projects.project(id, in: db) != nil else { throw OrganizationError.projectNotFound(id) }
            let owned = try tasks.tasks(matching: TaskQuery(projectID: .some(id)), in: db)
            for var task in owned {
                if deletingTasks {
                    try tasks.delete(task.id, in: db)
                } else {
                    task.projectID = nil
                    task.updatedAt = now
                    try tasks.save(task, in: db)
                }
            }
            try projects.delete(id, in: db)
            return owned
        }
        var published = affected.map {
            context.event(deletingTasks ? OrganizationEvent.taskDeleted : OrganizationEvent.taskUpdated, entity: $0.reference, at: now)
        }
        published.append(context.event(OrganizationEvent.projectDeleted, entity: EntityReference(kind: .project, id: id), at: now))
        events.publish(published)
    }

    public func project(_ id: Project.ID) async throws -> Project? {
        let projects = self.projects
        return try await database.read { db in try projects.project(id, in: db) }
    }

    public func projects(statuses: Set<ProjectStatus>? = nil) async throws -> [Project] {
        let projects = self.projects
        return try await database.read { db in try projects.projects(statuses: statuses, in: db) }
    }

    public func progress(of id: Project.ID) async throws -> ProjectProgress {
        let projects = self.projects
        let tasks = self.tasks
        let today = CalendarDate(timeSource.now(), calendar: calendar)
        let calendar = self.calendar
        return try await database.read { db in
            guard let project = try projects.project(id, in: db) else { throw OrganizationError.projectNotFound(id) }
            let owned = try tasks.tasks(matching: TaskQuery(projectID: .some(id)), in: db)
            return ProjectProgressCalculator.progress(for: project, tasks: owned, today: today, calendar: calendar)
        }
    }

    /// Progress of every planned, active or on-hold project, in display order.
    public func liveProjectProgress() async throws -> [(project: Project, progress: ProjectProgress)] {
        let projects = self.projects
        let tasks = self.tasks
        let today = CalendarDate(timeSource.now(), calendar: calendar)
        let calendar = self.calendar
        let pairs: [ProjectWithProgress] = try await database.read { db in
            let live = try projects.projects(statuses: [.planned, .active, .onHold], in: db)
            let all = try tasks.all(in: db)
            return live.map { project in
                ProjectWithProgress(project: project, progress: ProjectProgressCalculator.progress(for: project, tasks: all, today: today, calendar: calendar))
            }
        }
        return pairs.map { ($0.project, $0.progress) }
    }

    private func validated(_ project: Project) throws -> Project {
        try Self.validate(project)
    }

    static func validate(_ project: Project) throws -> Project {
        var project = project
        guard let name = project.name.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "name", reason: "A project needs a name.")
        }
        guard name.count <= maximumNameLength else {
            throw ValidationError(field: "name", reason: "Project names can be at most \(maximumNameLength) characters.")
        }
        project.name = name
        if let start = project.startDate, let target = project.targetDate, start > target {
            throw ValidationError(field: "target date", reason: "The target date must come after the start date.")
        }
        return project
    }
}

private struct ProjectWithProgress: Sendable {
    let project: Project
    let progress: ProjectProgress
}
