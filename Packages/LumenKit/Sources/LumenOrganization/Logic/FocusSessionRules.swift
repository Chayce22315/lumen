import Foundation
import LumenFoundation

/// Validation and state transitions of focus sessions. Pure: every function takes the instant it
/// applies at, so the same rules hold whichever process (or how much later) applies them.
public enum FocusSessionRules {
    public static let minimumMinutes = 1
    /// Four hours; longer stretches are better planned as several sessions.
    public static let maximumMinutes = 240
    public static let defaultMinutes = 25
    /// Durations offered as one-tap choices.
    public static let suggestedMinutes = [15, 25, 45, 60, 90]

    public static func validate(_ draft: FocusDraft) throws {
        guard (minimumMinutes...maximumMinutes).contains(draft.plannedMinutes) else {
            throw ValidationError(field: "duration", reason: "A focus session lasts between \(minimumMinutes) minute and \(maximumMinutes / 60) hours.")
        }
        if draft.completesTask && draft.taskID == nil {
            throw ValidationError(field: "task", reason: "Choose a task to complete when the session ends.")
        }
    }

    /// A new running session for a validated draft.
    public static func started(_ draft: FocusDraft, at now: Date) throws -> FocusSession {
        try validate(draft)
        return FocusSession(
            taskID: draft.taskID,
            plannedDuration: TimeInterval(draft.plannedMinutes) * 60,
            startedAt: now,
            completesTask: draft.completesTask && draft.taskID != nil
        )
    }

    /// The session as it stands at `now`: a running session whose countdown has run out is
    /// completed at the instant it reached zero (not at `now`), so its focused time is exactly the
    /// plan however late this is noticed. Anything else is returned unchanged.
    public static func settled(_ session: FocusSession, at now: Date) -> FocusSession {
        guard session.isDue(at: now) else { return session }
        var completed = session
        completed.endedAt = session.countdownEnd
        completed.outcome = .completed
        return completed
    }

    /// Pauses a running session; a paused one is returned unchanged, and one whose countdown ran
    /// out is returned completed.
    public static func paused(_ session: FocusSession, at now: Date) throws -> FocusSession {
        guard session.isActive else { throw OrganizationError.focusSessionEnded }
        let current = settled(session, at: now)
        guard current.isActive, current.pausedAt == nil else { return current }
        var paused = current
        // A clock that moved backwards must not pause before the session started.
        paused.pausedAt = max(now, session.startedAt)
        return paused
    }

    /// Resumes a paused session, adding the pause to `pausedDuration`; a running one is returned
    /// as it stands (completed if its countdown ran out).
    public static func resumed(_ session: FocusSession, at now: Date) throws -> FocusSession {
        guard session.isActive else { throw OrganizationError.focusSessionEnded }
        guard let pausedAt = session.pausedAt else { return settled(session, at: now) }
        var resumed = session
        resumed.pausedDuration += max(0, now.timeIntervalSince(pausedAt))
        resumed.pausedAt = nil
        return resumed
    }

    /// Ends an active session now. A pause in progress is folded into `pausedDuration`, so the
    /// focused time stops where the pause began. A session whose countdown already ran out is
    /// returned completed at that instant, whatever `outcome` was asked for: it was over by then.
    /// Ending is idempotent: a session that already ended is returned as it is (two devices'
    /// buttons, or a button and the countdown, may race to end it).
    public static func ended(_ session: FocusSession, as outcome: FocusOutcome, at now: Date) throws -> FocusSession {
        guard session.isActive else { return session }
        let current = settled(session, at: now)
        guard current.isActive else { return current }
        var ended = current
        let end = max(now, session.startedAt)
        if let pausedAt = session.pausedAt {
            ended.pausedDuration += max(0, end.timeIntervalSince(pausedAt))
            ended.pausedAt = nil
        }
        ended.endedAt = end
        ended.outcome = outcome
        return ended
    }
}
