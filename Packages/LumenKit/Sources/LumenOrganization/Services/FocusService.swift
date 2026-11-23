import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Focus sessions: starting one (at most one at a time), pausing, resuming, finishing and
/// cancelling it, and completing its task when asked to.
///
/// Every operation re-reads the stored session and applies `FocusSessionRules` at the current
/// instant, so a session whose countdown ran out while nothing was running (the app closed, the
/// device asleep) is completed at the instant it reached zero the next time anything touches it —
/// `completeIfDue()` is that touch for launches, activations and background refresh.
public final class FocusService: Sendable {
    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let tasks: TaskService
    private let logger: Logger
    private let sessions = FocusSessionRepository()
    private let taskRows = TaskRepository()

    public init(database: Database, events: EventBus, timeSource: any TimeSource, tasks: TaskService, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.tasks = tasks
        self.logger = logger
    }

    // MARK: - Starting

    /// Starts a session. Throws `focusSessionAlreadyActive` while another one is running or
    /// paused, and `focusTaskClosed` for a task that is done or cancelled.
    public func start(_ draft: FocusDraft, context: ActionContext = .user) async throws -> FocusSession {
        // A session whose countdown ran out is over; it must not block the new one.
        try await completeIfDue()
        let now = timeSource.now()
        let session = try FocusSessionRules.started(draft, at: now)
        let sessions = self.sessions
        let taskRows = self.taskRows
        try await database.write { db in
            if let taskID = session.taskID {
                guard let task = try taskRows.task(taskID, in: db) else { throw OrganizationError.taskNotFound(taskID) }
                guard task.isOpen else { throw OrganizationError.focusTaskClosed }
            }
            guard try sessions.active(in: db) == nil else { throw OrganizationError.focusSessionAlreadyActive }
            try sessions.save(session, in: db)
        }
        events.publish(context.event(OrganizationEvent.focusStarted, entity: session.reference, attributes: attributes(of: session), at: now))
        logger.info("Focus session started", metadata: ["minutes": String(session.plannedMinutes), "task": session.taskID == nil ? "no" : "yes"])
        return session
    }

    // MARK: - Changing

    /// Pauses the session. Pausing a paused session changes nothing; a session whose countdown
    /// already ran out is returned completed.
    @discardableResult
    public func pause(_ id: FocusSession.ID, context: ActionContext = .user) async throws -> FocusSession {
        try await transition(id, context: context) { session, now in try FocusSessionRules.paused(session, at: now) }.session
    }

    /// Resumes a paused session. Resuming a running session changes nothing.
    @discardableResult
    public func resume(_ id: FocusSession.ID, context: ActionContext = .user) async throws -> FocusSession {
        try await transition(id, context: context) { session, now in try FocusSessionRules.resumed(session, at: now) }.session
    }

    /// Ends the session as completed now (or at the instant its countdown ran out, if that was
    /// earlier), completing its task when the session asks for it.
    @discardableResult
    public func finish(_ id: FocusSession.ID, context: ActionContext = .user) async throws -> FocusEnding {
        try await transition(id, context: context) { session, now in try FocusSessionRules.ended(session, as: .completed, at: now) }
    }

    /// Ends the session without counting it. A session whose countdown had already run out is
    /// completed instead: it was over before the request.
    @discardableResult
    public func cancel(_ id: FocusSession.ID, context: ActionContext = .user) async throws -> FocusSession {
        try await transition(id, context: context) { session, now in try FocusSessionRules.ended(session, as: .cancelled, at: now) }.session
    }

    /// Completes the active session if its countdown has run out; `nil` when nothing was due.
    @discardableResult
    public func completeIfDue(context: ActionContext = .system) async throws -> FocusEnding? {
        let now = timeSource.now()
        guard let active = try await activeSession(), active.isDue(at: now) else { return nil }
        let ending = try await transition(active.id, context: context) { session, now in FocusSessionRules.settled(session, at: now) }
        return ending.session.isActive ? nil : ending
    }

    // MARK: - Reading

    /// The running or paused session, as stored. A running session can be due (its countdown
    /// at zero) until `completeIfDue()` or any other operation completes it.
    public func activeSession() async throws -> FocusSession? {
        let sessions = self.sessions
        return try await database.read { db in try sessions.active(in: db) }
    }

    public func session(_ id: FocusSession.ID) async throws -> FocusSession? {
        let sessions = self.sessions
        return try await database.read { db in try sessions.session(id, in: db) }
    }

    /// Sessions about one task, newest first.
    public func sessions(forTask taskID: TaskItem.ID) async throws -> [FocusSession] {
        let sessions = self.sessions
        return try await database.read { db in try sessions.sessions(forTask: taskID, in: db) }
    }

    /// The most recently started sessions, newest first.
    public func recentSessions(limit: Int = 20) async throws -> [FocusSession] {
        let sessions = self.sessions
        return try await database.read { db in try sessions.recent(limit: limit, in: db) }
    }

    /// Completed sessions about one task and their focused time.
    public func totals(forTask taskID: TaskItem.ID) async throws -> FocusTotals {
        let completed = try await sessions(forTask: taskID).filter { $0.phase == .completed }
        return FocusTotals(sessions: completed.count, focusedDuration: completed.reduce(0) { $0 + $1.focusedDuration(at: $1.endedAt ?? $1.startedAt) })
    }

    /// Seconds of focus in sessions completed in `[start, end)`.
    public func focusedDuration(from start: Date, to end: Date) async throws -> TimeInterval {
        let sessions = self.sessions
        let ended = try await database.read { db in try sessions.ended(between: start, and: end, in: db) }
        return ended.filter { $0.phase == .completed }.reduce(0) { $0 + $1.focusedDuration(at: $1.endedAt ?? $1.startedAt) }
    }

    // MARK: - Internals

    /// Applies `change` to the stored session at the current instant, saves it when it changed,
    /// publishes what happened and completes the task of a session that completed.
    private func transition(
        _ id: FocusSession.ID,
        context: ActionContext,
        _ change: @escaping @Sendable (FocusSession, Date) throws -> FocusSession
    ) async throws -> FocusEnding {
        let now = timeSource.now()
        let sessions = self.sessions
        let (before, after): (FocusSession, FocusSession) = try await database.write { db in
            guard let stored = try sessions.session(id, in: db) else { throw OrganizationError.focusSessionNotFound(id) }
            let changed = try change(stored, now)
            if changed != stored {
                try sessions.save(changed, in: db)
            }
            return (stored, changed)
        }
        guard before != after else { return FocusEnding(session: after, completedTask: nil) }

        let name: EventName
        switch after.phase {
        case .running: name = OrganizationEvent.focusResumed
        case .paused: name = OrganizationEvent.focusPaused
        case .completed: name = OrganizationEvent.focusCompleted
        case .cancelled: name = OrganizationEvent.focusCancelled
        }
        // A session completed because its countdown ran out is stamped with that instant, so
        // analytics counts it on the day it happened.
        let occurredAt = after.endedAt.map { min($0, now) } ?? now
        events.publish(context.event(name, entity: after.reference, attributes: attributes(of: after), at: occurredAt))
        if !after.isActive {
            logger.info("Focus session ended", metadata: ["outcome": after.phase.rawValue, "minutes": String(Int(after.focusedDuration(at: now) / 60))])
        }
        return FocusEnding(session: after, completedTask: try await completeTaskIfRequested(by: after, context: context))
    }

    private func completeTaskIfRequested(by session: FocusSession, context: ActionContext) async throws -> TaskItem? {
        guard session.phase == .completed, session.completesTask, let taskID = session.taskID else { return nil }
        do {
            return try await tasks.complete(taskID, context: context).completed
        } catch OrganizationError.taskNotFound(_) {
            // The task was deleted during the session; there is nothing left to complete.
            logger.notice("Focus task no longer exists; nothing to complete")
            return nil
        }
    }

    private func attributes(of session: FocusSession) -> [String: JSONValue] {
        var attributes: [String: JSONValue] = [
            "phase": .string(session.phase.rawValue),
            "plannedMinutes": .number(Double(session.plannedMinutes)),
        ]
        if let taskID = session.taskID { attributes["taskID"] = .string(taskID.uuidString) }
        if let endedAt = session.endedAt {
            let focused = session.focusedDuration(at: endedAt)
            attributes["focusedSeconds"] = .number(focused.rounded())
            attributes["focusedMinutes"] = .number(focused / 60)
        }
        return attributes
    }
}
