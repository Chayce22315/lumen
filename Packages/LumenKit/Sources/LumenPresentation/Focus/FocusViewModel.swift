import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// The Focus screen for one session: its countdown, pause/resume, finishing or cancelling it,
/// and a summary once it ended. Everything shown is computed from the session's timestamps; the
/// screen's countdown text animates itself, and the session completes (and this model reloads)
/// when the coordinator notices the countdown ran out.
@MainActor
@Observable
public final class FocusViewModel {
    public let sessionID: FocusSession.ID
    public private(set) var state: LoadState<FocusSession> = .idle
    /// The task's title; `nil` without a task or when it was deleted.
    public private(set) var taskTitle: String?
    /// The task is done (for example because the session completed it).
    public private(set) var isTaskDone = false
    public private(set) var isWorking = false
    public private(set) var error: ErrorPresentation?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(sessionID: FocusSession.ID, services: LumenServices) {
        self.sessionID = sessionID
        self.services = services
    }

    /// Loads, then follows changes to the session (from Live Activity buttons, Siri, the
    /// assistant, automations or the countdown running out).
    public func start() async {
        await load()
        services.events.observe(
            EventFilter(names: Set(OrganizationEvent.focusEvents + [OrganizationEvent.taskCompleted, OrganizationEvent.taskReopened, OrganizationEvent.taskUpdated])),
            debounce: 0.1,
            into: observation
        ) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            guard let session = try await services.focus.service.session(sessionID) else {
                state = .failed(OrganizationError.focusSessionNotFound(sessionID).presentation)
                return
            }
            var task: TaskItem?
            if let taskID = session.taskID {
                task = try await services.organization.tasks.task(taskID)
            }
            taskTitle = task?.title
            isTaskDone = task?.status == .done
            state = .loaded(session)
        } catch {
            if state.value == nil {
                state = .failed(ErrorPresentation.from(error))
            } else {
                services.errors.report(error, context: "Refreshing the focus session")
            }
        }
    }

    public var session: FocusSession? { state.value }

    /// "Focus" for a session without a task.
    public var title: String { taskTitle ?? "Focus" }

    public var phase: FocusPhase? { session?.phase }

    /// The span a countdown text runs over: exactly the planned length, ending when the time is up.
    public var countdownRange: ClosedRange<Date>? {
        guard let session else { return nil }
        return min(session.countdownStart, session.countdownEnd)...max(session.countdownStart, session.countdownEnd)
    }

    /// Where a paused countdown is frozen.
    public var pausedAt: Date? { session?.pausedAt }

    public func remaining(at now: Date) -> TimeInterval {
        session?.remainingDuration(at: now) ?? 0
    }

    public func progress(at now: Date) -> Double {
        session?.progress(at: now) ?? 0
    }

    /// For VoiceOver: "12 minutes left", "Paused, 12 minutes left", "Completed: 25 minutes of focus".
    public func status(at now: Date) -> String {
        guard let session else { return "" }
        switch session.phase {
        case .running:
            return "\(FocusIntegration.durationText(ceilToMinute(session.remainingDuration(at: now)))) left"
        case .paused:
            return "Paused, \(FocusIntegration.durationText(ceilToMinute(session.remainingDuration(at: now)))) left"
        case .completed:
            return "Completed: \(FocusIntegration.durationText(session.focusedDuration(at: now))) of focus"
        case .cancelled:
            return "Cancelled after \(FocusIntegration.durationText(session.focusedDuration(at: now)))"
        }
    }

    /// The summary line of an ended session.
    public var summary: String? {
        guard let session, let endedAt = session.endedAt else { return nil }
        let focused = FocusIntegration.durationText(session.focusedDuration(at: endedAt))
        switch session.phase {
        case .completed:
            return isTaskDone && session.completesTask ? "\(focused) of focus. Task completed." : "\(focused) of focus."
        case .cancelled:
            return "Cancelled after \(focused). This time isn't counted."
        case .running, .paused:
            return nil
        }
    }

    // MARK: - Intents

    public func pause() async {
        await perform("Pausing focus") { try await $0.pause($1) }
    }

    public func resume() async {
        await perform("Resuming focus") { try await $0.resume($1) }
    }

    public func finish() async {
        await perform("Finishing focus") { try await $0.finish($1).session }
    }

    public func cancel() async {
        await perform("Cancelling focus") { try await $0.cancel($1) }
    }

    private func perform(_ context: String, _ change: @escaping @Sendable (FocusService, FocusSession.ID) async throws -> FocusSession) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            state = .loaded(try await change(services.focus.service, sessionID))
            await load()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// Whole minutes, rounded up, so "1 minute left" lasts until the countdown reaches zero.
    private func ceilToMinute(_ seconds: TimeInterval) -> TimeInterval {
        (seconds / 60).rounded(.up) * 60
    }
}
