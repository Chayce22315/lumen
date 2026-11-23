import Foundation
import Observation
import LumenFoundation
import LumenApplication

/// Settings › "Show in Spotlight": whether tasks and notes appear in system search.
@MainActor
@Observable
public final class SpotlightSettingsViewModel {
    public private(set) var isEnabled = true
    /// Turning it on rebuilds the index, which can take a moment with many items.
    public private(set) var isUpdating = false

    private let services: LumenServices

    public init(services: LumenServices) {
        self.services = services
    }

    /// Whether this device has a system search index; without one the setting is not shown.
    public var isAvailable: Bool { services.spotlight.isAvailable }

    public func load() async {
        isEnabled = await services.spotlight.isEnabled()
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isEnabled = enabled
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await services.spotlight.setEnabled(enabled)
        } catch {
            services.errors.report(error, context: enabled ? "Adding Lumen to Spotlight" : "Removing Lumen from Spotlight")
        }
        isEnabled = await services.spotlight.isEnabled()
    }
}
