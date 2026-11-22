import Foundation
import LumenApplication

/// One `LumenServices` per process, shared by the interface and App Intents so both work on the
/// same database connection, event bus and caches.
public actor SharedServices {
    public static let shared = SharedServices()

    private var creation: Task<LumenServices, any Error>?

    public func services() async throws -> LumenServices {
        if let creation {
            return try await creation.value
        }
        let creation = Task { try await LivePlatform.makeServices() }
        self.creation = creation
        do {
            return try await creation.value
        } catch {
            // Allow a later attempt (for example after the device is unlocked).
            self.creation = nil
            throw error
        }
    }
}
