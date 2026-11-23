#if canImport(ActivityKit) && os(iOS)
import Foundation
import ActivityKit

/// The focus Live Activity's ActivityKit type, shared by the app (which starts, updates and ends
/// it) and the widget extension (which renders it). Fixed for the activity's lifetime; everything
/// that changes is in `FocusActivityState`.
public struct FocusActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = FocusActivityState

    public var sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    public var deepLink: URL? { FocusActivityLink.url(sessionID: sessionID) }
}
#endif
