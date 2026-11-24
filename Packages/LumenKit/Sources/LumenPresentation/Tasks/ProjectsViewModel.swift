import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// Projects with their progress and health, plus creation.
@MainActor
@Observable
public final class ProjectsViewModel {
    public struct Row: Sendable, Hashable, Identifiable {
        public let project: Project
        public let progress: ProjectProgress
        public var id: Project.ID { project.id }

        public var progressLabel: String {
            "\(progress.completedTasks) of \(progress.totalTasks - progress.cancelledTasks) done"
        }
    }

    public private(set) var state: LoadState<[Row]> = .idle
    public var showsCompleted = false {
        didSet { Task { await load() } }
    }
    // Creation form.
    public var newName = ""
    public var newColor: ProjectColor = .blue
    public var newTargetDate: CalendarDate?
    public private(set) var error: ErrorPresentation?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .project]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            let projects = services.organization.projects
            let statuses: Set<ProjectStatus> = showsCompleted ? Set(ProjectStatus.allCases) : [.planned, .active, .onHold]
            var rows: [Row] = []
            for project in try await projects.projects(statuses: statuses) {
                rows.append(Row(project: project, progress: try await projects.progress(of: project.id)))
            }
            state = .loaded(rows)
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public var canCreate: Bool { newName.collapsingWhitespace.nonBlank != nil }

    @discardableResult
    public func create() async -> Project? {
        error = nil
        do {
            let project = try await services.organization.projects.create(name: newName, color: newColor, targetDate: newTargetDate)
            newName = ""
            newTargetDate = nil
            await load()
            return project
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }

    public func setStatus(_ status: ProjectStatus, for id: Project.ID) async {
        do {
            _ = try await services.organization.projects.setStatus(id, status)
            await load()
        } catch {
            services.errors.report(error, context: "Updating a project")
        }
    }

    public func delete(_ id: Project.ID, deletingTasks: Bool) async {
        do {
            try await services.organization.projects.delete(id, deletingTasks: deletingTasks)
            await load()
        } catch {
            services.errors.report(error, context: "Deleting a project")
        }
    }
}
