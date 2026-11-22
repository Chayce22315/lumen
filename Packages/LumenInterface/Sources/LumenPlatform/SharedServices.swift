import Foundation
import LumenApplication

/// One `LumenServices` per process, shared by the interface and App Intents so both work on the
/// same database connection, event bus and caches.
public actor SharedServices {
    public static let shared = SharedServices()

    private var creation: Task<LumenServices, any Error>?
    private var sharedRuntime: LumenRuntime?

    /// The runtime for the shared services, used by the interface and by background refresh so
    /// engines are started once per process.
    public func runtime() async throws -> LumenRuntime {
        if let sharedRuntime { return sharedRuntime }
        let services = try await services()
        // Another caller may have created it while this one waited for the services.
        if let sharedRuntime { return sharedRuntime }
        let runtime = LumenRuntime(services: services)
        sharedRuntime = runtime
        return runtime
    }

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
