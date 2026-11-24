import Foundation
import LumenOrganization

/// Focus sessions and what keeps the system around them (Live Activity, end-of-session alert,
/// completion of a countdown that ran out) in step.
public struct FocusServices: Sendable {
    /// Starting, pausing, resuming and ending sessions.
    public let service: FocusService
    /// Call `reconcile()` after changing a session from a process whose runtime may not run
    /// (App Intents), so the Live Activity reflects the change before the intent returns.
    public let coordinator: FocusCoordinator

    public init(service: FocusService, coordinator: FocusCoordinator) {
        self.service = service
        self.coordinator = coordinator
    }
}
