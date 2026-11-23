import Foundation
import LumenFoundation

/// How a focus session ended.
public enum FocusOutcome: String, Sendable, Codable, Hashable, CaseIterable {
    /// The countdown ran out, or the user finished early. Its focused time counts.
    case completed
    /// Abandoned. Its time is not counted as focus.
    case cancelled
}

/// Where a focus session stands.
public enum FocusPhase: String, Sendable, Codable, Hashable, CaseIterable {
    case running
    case paused
    case completed
    case cancelled

    public var isActive: Bool { self == .running || self == .paused }
}

/// A planned stretch of focused work, optionally on one task.
///
/// Progress is derived only from timestamps — when it started, when the current pause began, how
/// long earlier pauses lasted and when it ended — never from a running timer, so a session reads
/// the same after a relaunch and in every process (the app, App Intents, Live Activity buttons).
/// Sessions are device-local: they are not part of the change log and do not synchronize.
public struct FocusSession: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<FocusSession>

    public let id: ID
    /// The task being worked on, if any. It may since have been deleted.
    public var taskID: TaskItem.ID?
    /// Seconds of focus planned.
    public var plannedDuration: TimeInterval
    public var startedAt: Date
    /// When the current pause began; `nil` while running and once ended.
    public var pausedAt: Date?
    /// Total seconds of pauses that are over (resumed, or folded in when the session ended while
    /// paused). The current pause is not included.
    public var pausedDuration: TimeInterval
    public var endedAt: Date?
    public var outcome: FocusOutcome?
    /// Complete `taskID` when the session completes.
    public var completesTask: Bool

    public init(
        id: ID = ID(),
        taskID: TaskItem.ID? = nil,
        plannedDuration: TimeInterval,
        startedAt: Date,
        pausedAt: Date? = nil,
        pausedDuration: TimeInterval = 0,
        endedAt: Date? = nil,
        outcome: FocusOutcome? = nil,
        completesTask: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.pausedDuration = pausedDuration
        self.endedAt = endedAt
        self.outcome = outcome
        self.completesTask = completesTask
    }

    public var reference: EntityReference { EntityReference(kind: .focusSession, id: id) }

    /// Running or paused.
    public var isActive: Bool { endedAt == nil }

    public var isPaused: Bool { isActive && pausedAt != nil }

    public var phase: FocusPhase {
        if endedAt != nil { return outcome == .cancelled ? .cancelled : .completed }
        return pausedAt == nil ? .running : .paused
    }

    public var plannedMinutes: Int { Int((plannedDuration / 60).rounded()) }

    /// The instant the countdown reaches zero if it runs without further pauses. While paused it
    /// moves later with every second of the pause; `countdownStart...countdownEnd` always spans
    /// exactly `plannedDuration`, which is what a system countdown text needs.
    public var countdownEnd: Date { startedAt.addingTimeInterval(pausedDuration + plannedDuration) }

    public var countdownStart: Date { startedAt.addingTimeInterval(pausedDuration) }

    /// Seconds of focus so far: time since the start, less every pause, up to the end (or the
    /// start of the current pause). Never negative, even if the clock moved backwards.
    public func focusedDuration(at now: Date) -> TimeInterval {
        let until = endedAt ?? pausedAt ?? now
        return max(0, until.timeIntervalSince(startedAt) - pausedDuration)
    }

    /// Seconds left on the countdown at `now`, never negative.
    public func remainingDuration(at now: Date) -> TimeInterval {
        max(0, plannedDuration - focusedDuration(at: now))
    }

    /// Share of the plan done, 0…1.
    public func progress(at now: Date) -> Double {
        guard plannedDuration > 0 else { return 1 }
        return min(1, focusedDuration(at: now) / plannedDuration)
    }

    /// A running session whose countdown has run out; it completes the next time it is touched.
    public func isDue(at now: Date) -> Bool {
        phase == .running && now >= countdownEnd
    }
}

/// What starting a focus session needs.
public struct FocusDraft: Sendable, Hashable {
    public var taskID: TaskItem.ID?
    public var plannedMinutes: Int
    /// Complete the task when the session completes. Requires `taskID`.
    public var completesTask: Bool

    public init(taskID: TaskItem.ID? = nil, plannedMinutes: Int = FocusSessionRules.defaultMinutes, completesTask: Bool = false) {
        self.taskID = taskID
        self.plannedMinutes = plannedMinutes
        self.completesTask = completesTask
    }
}

/// The result of ending a session.
public struct FocusEnding: Sendable, Hashable {
    public let session: FocusSession
    /// The task completed because the session asked for it, when that happened.
    public let completedTask: TaskItem?

    public init(session: FocusSession, completedTask: TaskItem?) {
        self.session = session
        self.completedTask = completedTask
    }
}

/// Totals for the sessions of one task.
public struct FocusTotals: Sendable, Hashable {
    /// Completed sessions.
    public let sessions: Int
    /// Seconds of focus across them.
    public let focusedDuration: TimeInterval

    public init(sessions: Int, focusedDuration: TimeInterval) {
        self.sessions = sessions
        self.focusedDuration = focusedDuration
    }

    public static let zero = FocusTotals(sessions: 0, focusedDuration: 0)
}
