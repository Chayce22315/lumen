import Foundation
import LumenFoundation
import LumenOrganization
import LumenWidgetData

/// Shows the focus session outside the app: a Live Activity on the Lock Screen and in the
/// Dynamic Island. The app's adapter (ActivityKit, in `LumenPlatform`) respects the user's Live
/// Activities setting; environments without one use `InertFocusActivityPresenter`.
public protocol FocusActivityPresenting: Sendable {
    /// Shows `content`. For an active session: updates its activity, or starts one and ends the
    /// activities of other sessions. For an ended session: ends its activity showing this final
    /// content. `nil`: no session is active; ends every focus activity that is still running.
    func present(_ content: FocusActivityContent?) async throws
}

/// For tests, previews and platforms without Live Activities.
public struct InertFocusActivityPresenter: FocusActivityPresenting {
    public init() {}
    public func present(_ content: FocusActivityContent?) async throws {}
}

extension FocusActivityContent {
    /// The Live Activity content for `session`, computed from its timestamps.
    public init(session: FocusSession, title: String?) {
        let phase: FocusActivityState.Phase
        switch session.phase {
        case .running: phase = .running
        case .paused: phase = .paused
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        }
        self.init(
            sessionID: session.id.rawValue,
            state: FocusActivityState(
                phase: phase,
                title: title,
                countdownStart: session.countdownStart,
                countdownEnd: session.countdownEnd,
                pausedAt: session.pausedAt,
                plannedDuration: session.plannedDuration,
                focusedDuration: session.endedAt.map { session.focusedDuration(at: $0) } ?? 0
            )
        )
    }
}
