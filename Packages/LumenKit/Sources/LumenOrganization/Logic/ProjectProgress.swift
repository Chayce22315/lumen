import Foundation
import LumenFoundation

public enum ProjectHealth: String, Sendable, Codable, Hashable {
    /// Nothing overdue and the target date (if any) is not at risk.
    case onTrack
    /// Overdue tasks, or the target date is close relative to the remaining work.
    case atRisk
    /// The target date has passed with work remaining.
    case offTrack
    /// The project is completed or archived.
    case closed
}

public struct ProjectProgress: Sendable, Hashable {
    public let projectID: Project.ID
    public let totalTasks: Int
    public let completedTasks: Int
    public let cancelledTasks: Int
    public let openTasks: Int
    public let overdueTasks: Int
    /// Completed / (total − cancelled), `0...1`; `0` for a project without countable tasks.
    public let fractionComplete: Double
    /// The first actionable task: open, not blocked, ordered by `TaskOrdering.actionableFirst`.
    public let nextAction: TaskItem?
    public let health: ProjectHealth
    public let daysUntilTarget: Int?
}

public enum ProjectProgressCalculator {
    /// Schedule risk only applies once half of the time between start and target has elapsed;
    /// from then on, the share of completed work must keep up with the share of elapsed time.
    static let riskThreshold = 0.5

    /// - Parameter calendar: converts the creation instant to a start day when the project has no explicit start date.
    public static func progress(for project: Project, tasks: [TaskItem], today: CalendarDate, calendar: Calendar) -> ProjectProgress {
        let own = tasks.filter { $0.projectID == project.id }
        let completed = own.filter { $0.status == .done }.count
        let cancelled = own.filter { $0.status == .cancelled }.count
        let open = own.filter(\.isOpen)
        let overdue = open.filter { $0.isOverdue(today: today) }.count
        let countable = own.count - cancelled
        let fraction = countable > 0 ? Double(completed) / Double(countable) : 0

        let statuses = Dictionary(own.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let graph = DependencyGraph(tasks: own)
        let nextAction = open
            .filter { !graph.isBlocked($0.id, statuses: statuses) && $0.parentID == nil }
            .sorted(by: TaskOrdering.actionableFirst)
            .first

        let daysUntilTarget = project.targetDate.map { $0.days(since: today) }
        let health: ProjectHealth
        if !project.status.isLive {
            health = .closed
        } else if let days = daysUntilTarget, days < 0, !open.isEmpty {
            health = .offTrack
        } else if overdue > 0 {
            health = .atRisk
        } else if let target = project.targetDate, !open.isEmpty,
                  case let start = project.startDate ?? CalendarDate(project.createdAt, calendar: calendar), target > start {
            let total = Double(target.days(since: start))
            let elapsed = Double(today.days(since: start))
            let timeFraction = min(max(elapsed / total, 0), 1)
            health = timeFraction >= riskThreshold && fraction < timeFraction ? .atRisk : .onTrack
        } else {
            health = .onTrack
        }

        return ProjectProgress(
            projectID: project.id,
            totalTasks: own.count,
            completedTasks: completed,
            cancelledTasks: cancelled,
            openTasks: open.count,
            overdueTasks: overdue,
            fractionComplete: fraction,
            nextAction: nextAction,
            health: health,
            daysUntilTarget: daysUntilTarget
        )
    }
}
