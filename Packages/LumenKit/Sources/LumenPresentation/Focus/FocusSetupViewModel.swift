import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// Starting a focus session, optionally on a task: the length (a suggestion or any whole number
/// of minutes within the allowed range) and whether to complete the task when it ends. While
/// another session runs, it offers that one instead.
@MainActor
@Observable
public final class FocusSetupViewModel {
    public let taskID: TaskItem.ID?
    public private(set) var taskTitle: String?
    /// Minutes planned, kept within `minuteRange`.
    public var minutes: Int = FocusSessionRules.defaultMinutes {
        didSet {
            let clamped = min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound)
            if clamped != minutes { minutes = clamped }
        }
    }
    /// Complete the task when the session completes. Only offered with a task.
    public var completesTask = false
    /// The session already running or paused; a new one can't start until it ends.
    public private(set) var activeSession: FocusSession?
    public private(set) var isLoaded = false
    public private(set) var isStarting = false
    public private(set) var error: ErrorPresentation?

    public let suggestedMinutes = FocusSessionRules.suggestedMinutes
    public let minuteRange = FocusSessionRules.minimumMinutes...FocusSessionRules.maximumMinutes

    private let services: LumenServices

    public init(taskID: TaskItem.ID? = nil, services: LumenServices) {
        self.taskID = taskID
        self.services = services
    }

    public func load() async {
        do {
            if let taskID {
                let task = try await services.organization.tasks.task(taskID)
                taskTitle = task?.title
                // A task with an estimate suggests it, within the allowed range.
                if let estimate = task?.estimatedMinutes, estimate > 0, !isLoaded {
                    minutes = estimate
                }
            }
            activeSession = try await services.focus.service.activeSession()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
        isLoaded = true
    }

    public var offersTaskCompletion: Bool { taskID != nil }

    public var canStart: Bool { isLoaded && activeSession == nil && !isStarting }

    /// "25 minutes", for the length control's value.
    public var minutesLabel: String { FocusIntegration.durationText(TimeInterval(minutes) * 60) }

    /// Starts the session; returns it so the caller can open the Focus screen.
    @discardableResult
    public func start() async -> FocusSession? {
        guard canStart else { return nil }
        isStarting = true
        error = nil
        defer { isStarting = false }
        do {
            let draft = FocusDraft(taskID: taskID, plannedMinutes: minutes, completesTask: offersTaskCompletion && completesTask)
            return try await services.focus.service.start(draft)
        } catch OrganizationError.focusSessionAlreadyActive {
            error = OrganizationError.focusSessionAlreadyActive.presentation
            await load()
            return nil
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }
}

/// The running or paused session for Home and toolbars: what it is about and when it ends.
@MainActor
@Observable
public final class ActiveFocusViewModel {
    public private(set) var session: FocusSession?
    public private(set) var taskTitle: String?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(names: Set(OrganizationEvent.focusEvents)), debounce: 0.1, into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        do {
            let active = try await services.focus.service.activeSession()
            var title: String?
            if let taskID = active?.taskID {
                title = try await services.organization.tasks.task(taskID)?.title
            }
            session = active
            taskTitle = title
        } catch {
            services.errors.report(error, context: "Reading the focus session")
        }
    }

    public var title: String { taskTitle ?? "Focus session" }

    public var countdownRange: ClosedRange<Date>? {
        guard let session else { return nil }
        return min(session.countdownStart, session.countdownEnd)...max(session.countdownStart, session.countdownEnd)
    }
}
