import Foundation
import LumenFoundation
import LumenApplication
import LumenWidgetData
#if canImport(ActivityKit) && os(iOS)
@preconcurrency import ActivityKit
#endif

/// The focus session as a Live Activity on the Lock Screen and in the Dynamic Island, through
/// ActivityKit — local updates only: no push token, no entitlement. The widget extension renders
/// it (`FocusLiveActivity`); its countdown animates by itself, so the app only updates the
/// activity when the session changes (start, pause, resume, end).
///
/// Respects the user's Live Activities setting (`areActivitiesEnabled`): nothing new is started
/// while it is off. Needs `NSSupportsLiveActivities` in the app's Info.plist.
public struct LiveActivityFocusPresenter: FocusActivityPresenting {
    /// How long a completed session's final state stays on the Lock Screen.
    public static let completedDismissalDelay: TimeInterval = 10 * 60

    private let timeSource: any TimeSource

    public init(timeSource: any TimeSource = SystemTimeSource()) {
        self.timeSource = timeSource
    }

    public func present(_ content: FocusActivityContent?) async throws {
        #if canImport(ActivityKit) && os(iOS)
        let all = Activity<FocusActivityAttributes>.activities
        let live = all.filter { $0.activityState == .active || $0.activityState == .stale }

        // Nothing is active: end whatever is still counting down (a final state stays).
        guard let content else {
            for activity in live {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let update = ActivityContent(state: content.state, staleDate: content.state.staleDate)
        let mine = live.filter { $0.attributes.sessionID == content.sessionID }

        // The session ended: show its final state, briefly for a completion, not at all for a
        // cancellation.
        guard content.state.isActive else {
            let policy: ActivityUIDismissalPolicy = content.state.phase == .completed
                ? .after(timeSource.now().addingTimeInterval(Self.completedDismissalDelay))
                : .immediate
            for activity in mine {
                await activity.end(update, dismissalPolicy: policy)
            }
            return
        }

        // One focus activity at a time.
        for other in live where other.attributes.sessionID != content.sessionID {
            await other.end(nil, dismissalPolicy: .immediate)
        }
        if let existing = mine.first {
            await existing.update(update)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try Activity<FocusActivityAttributes>.request(
            attributes: FocusActivityAttributes(sessionID: content.sessionID),
            content: update,
            pushType: nil
        )
        #endif
    }
}
