import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenWidgetData

/// Keeps everything around the focus session in step with what is stored: the Live Activity, the
/// "session complete" notification at the countdown's end, and completing a session whose
/// countdown ran out.
///
/// It reacts to `organization.focus.*` events while the runtime runs, and `reconcile()` brings
/// everything in line from storage alone — on launch, on activation, in background refresh and
/// from App Intents that may run before the runtime starts. Nothing depends on a timer having
/// fired: the countdown wake-up only makes the completion prompt; a missed one is caught up by the
/// next reconcile with the same result, because completion is computed from timestamps.
public actor FocusCoordinator {
    private enum AlertState: Equatable {
        /// Nothing is known (a fresh process): the next sync clears whatever may be pending.
        case unknown
        case none
        case scheduled(FocusSession.ID, at: Date)
    }

    private let focus: FocusService
    private let tasks: TaskService
    private let notifications: NotificationService
    private let presenter: any FocusActivityPresenting
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger
    private var consumer: Task<Void, Never>?
    private var countdown: Task<Void, Never>?
    /// The last queued unit of work. Work runs one unit at a time, in order: the actor alone
    /// would interleave two updates at their suspension points (posting an alert twice, or
    /// cancelling the one just posted).
    private var tail: Task<Void, Never>?
    private var alert: AlertState = .unknown
    /// Focus events handled since `start()`, for deterministic waiting in tests.
    public private(set) var handledEvents = 0

    public init(
        focus: FocusService,
        tasks: TaskService,
        notifications: NotificationService,
        presenter: any FocusActivityPresenting,
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger
    ) {
        self.focus = focus
        self.tasks = tasks
        self.notifications = notifications
        self.presenter = presenter
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
    }

    /// Follows focus events. Idempotent.
    public func start() {
        guard consumer == nil else { return }
        let stream = events.events(matching: EventFilter(names: Set(OrganizationEvent.focusEvents)))
        consumer = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        tail = nil
        countdown?.cancel()
        countdown = nil
    }

    /// Completes a session whose countdown ran out, then shows the active session (or the one
    /// that just completed) and schedules its alert and wake-up — or clears them when nothing is
    /// active. Safe to call any number of times.
    public func reconcile() async {
        await serially { await $0.bringUpToDate() }
    }

    /// Runs `work` after every unit queued before it.
    private func serially(_ work: @escaping @Sendable (FocusCoordinator) async -> Void) async {
        let previous = tail
        let next = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        tail = next
        await next.value
    }

    private func bringUpToDate() async {
        do {
            let ending = try await focus.completeIfDue()
            if let active = try await focus.activeSession() {
                await show(active)
            } else if let ended = ending?.session {
                await show(ended)
            } else {
                countdown?.cancel()
                countdown = nil
                await present(nil)
                await syncAlert(for: nil)
            }
        } catch {
            logger.error("Focus session could not be brought up to date", error: error)
        }
    }

    /// Waits (bounded) until at least `count` events have been handled.
    public func waitForHandledEvents(_ count: Int, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while handledEvents < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000) // Polling pause; cancellation ends the wait early.
        }
    }

    // MARK: - Internals

    private func handle(_ event: DomainEvent) async {
        let ended = event.name == OrganizationEvent.focusCompleted || event.name == OrganizationEvent.focusCancelled
        let id = event.entity.map { FocusSession.ID($0.id) }
        await serially { coordinator in
            if ended, let id {
                await coordinator.showFinalState(of: id)
            }
            await coordinator.bringUpToDate()
        }
        handledEvents += 1
    }

    /// The ended session's activity shows its final state; then whatever is active now (perhaps
    /// a session started right after) takes over the countdown and the alert.
    private func showFinalState(of id: FocusSession.ID) async {
        do {
            if let session = try await focus.session(id), !session.isActive {
                await present(FocusActivityContent(session: session, title: await title(of: session)))
            }
        } catch {
            logger.error("Ended focus session could not be read", error: error)
        }
    }

    /// Shows the active session or, when none is active, the one that just ended.
    private func show(_ session: FocusSession) async {
        scheduleCountdown(for: session)
        let title = await title(of: session)
        await present(FocusActivityContent(session: session, title: title))
        await syncAlert(for: session, title: title)
    }

    private func title(of session: FocusSession) async -> String? {
        guard let taskID = session.taskID else { return nil }
        do {
            return try await tasks.task(taskID)?.title
        } catch {
            // The activity still shows the countdown; only the task's name is missing.
            logger.error("Focus task could not be read", error: error)
            return nil
        }
    }

    private func present(_ content: FocusActivityContent?) async {
        do {
            try await presenter.present(content)
        } catch {
            logger.error("Focus Live Activity could not be updated", error: error)
        }
    }

    /// Wakes up when a running countdown reaches zero (plus a moment, so the session is due by
    /// then); any earlier wake-up is cancelled.
    private func scheduleCountdown(for session: FocusSession) {
        countdown?.cancel()
        countdown = nil
        guard session.phase == .running else { return }
        let delay = max(0, session.countdownEnd.timeIntervalSince(timeSource.now())) + 0.5
        countdown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) // Cancelled when the session changes.
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// One pending notification at the end of a running countdown; none otherwise.
    private func syncAlert(for session: FocusSession?, title: String? = nil) async {
        let desired: AlertState
        if let session, session.phase == .running {
            desired = .scheduled(session.id, at: session.countdownEnd)
        } else {
            desired = .none
        }
        guard desired != alert else { return }
        do {
            if case .scheduled(let previous, _) = alert {
                try await notifications.cancelPending(for: EntityReference(kind: .focusSession, id: previous))
            }
            // A previous process may have scheduled one for this session.
            if let session {
                try await notifications.cancelPending(for: session.reference)
            }
            if case .scheduled = desired, let session {
                try await notifications.post(Self.alert(for: session, title: title))
            }
            alert = desired
        } catch {
            alert = .unknown
            logger.error("Focus notification could not be scheduled", error: error)
        }
    }

    static func alert(for session: FocusSession, title: String?) -> NotificationDraft {
        let minutes = session.plannedMinutes == 1 ? "1 minute" : "\(session.plannedMinutes) minutes"
        let body = title.map { "\($0) · \(minutes) of focus." } ?? "\(minutes) of focus."
        // The user set this countdown, so it is time-sensitive like a reminder they scheduled.
        return NotificationDraft(
            category: .reminder,
            title: "Focus session complete",
            body: body,
            entity: session.reference,
            deliverAt: session.countdownEnd,
            bypassesQuietHours: true
        )
    }
}
