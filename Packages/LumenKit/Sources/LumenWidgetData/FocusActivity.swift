import Foundation

/// What the focus Live Activity shows: the app computes it from the focus session's timestamps
/// and ActivityKit stores it as the activity's content state, which the widget extension renders.
/// Nothing here runs a timer; the system's countdown text and progress views animate it.
public struct FocusActivityState: Sendable, Codable, Hashable {
    public enum Phase: String, Sendable, Codable, Hashable {
        case running
        case paused
        case completed
        case cancelled
    }

    public var phase: Phase
    /// The task's title; `nil` for a session without a task.
    public var title: String?
    /// The countdown runs from `countdownStart` to `countdownEnd`, exactly the planned length
    /// apart. While running, the time left is `countdownEnd - now`.
    public var countdownStart: Date
    public var countdownEnd: Date
    /// When the current pause began. A countdown frozen at this instant shows the time left.
    public var pausedAt: Date?
    public var plannedDuration: TimeInterval
    /// Seconds focused, for an ended session's summary (0 while active).
    public var focusedDuration: TimeInterval

    public init(
        phase: Phase,
        title: String?,
        countdownStart: Date,
        countdownEnd: Date,
        pausedAt: Date?,
        plannedDuration: TimeInterval,
        focusedDuration: TimeInterval
    ) {
        self.phase = phase
        self.title = title
        self.countdownStart = countdownStart
        self.countdownEnd = countdownEnd
        self.pausedAt = pausedAt
        self.plannedDuration = plannedDuration
        self.focusedDuration = focusedDuration
    }

    public var isActive: Bool { phase == .running || phase == .paused }

    /// `countdownStart...countdownEnd`, never inverted (an inverted range would trap).
    public var countdownRange: ClosedRange<Date> {
        min(countdownStart, countdownEnd)...max(countdownStart, countdownEnd)
    }

    /// Seconds left at `now`: frozen while paused, never negative.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, countdownEnd.timeIntervalSince(pausedAt ?? now))
    }

    /// Share of the plan done at `now`, 0…1.
    public func progress(at now: Date) -> Double {
        guard plannedDuration > 0 else { return 1 }
        if !isActive { return min(1, focusedDuration / plannedDuration) }
        return min(1, max(0, 1 - remaining(at: now) / plannedDuration))
    }

    /// When the content goes out of date: the end of a running countdown, after which the app
    /// completes the session. Paused and ended content stays valid.
    public var staleDate: Date? { phase == .running ? countdownEnd : nil }

    /// Whole minutes, rounded, for labels.
    public var plannedMinutes: Int { Int((plannedDuration / 60).rounded()) }
    public var focusedMinutes: Int { Int((focusedDuration / 60).rounded()) }
}

/// One session's Live Activity content.
public struct FocusActivityContent: Sendable, Codable, Hashable {
    public var sessionID: UUID
    public var state: FocusActivityState

    public init(sessionID: UUID, state: FocusActivityState) {
        self.sessionID = sessionID
        self.state = state
    }
}

/// Links from the Live Activity into the app.
public enum FocusActivityLink {
    /// `lumen://entity/focus-session:<UUID>`, which the app's `DeepLink` opens on the session's
    /// Focus screen. The kind must match `EntityKind.focusSession`.
    public static func url(sessionID: UUID) -> URL? {
        URL(string: "lumen://entity/focus-session:\(sessionID.uuidString)")
    }
}
