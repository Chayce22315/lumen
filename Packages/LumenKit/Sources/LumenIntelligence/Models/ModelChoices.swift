import Foundation
import LumenFoundation

/// The models this device can answer with right now: those of providers that are configured
/// (an API key is stored, or none is needed) and whose model list could be loaded.
public struct ModelChoices: Sendable, Hashable {
    public struct ProviderModels: Sendable, Hashable, Identifiable {
        public let id: ProviderID
        public let displayName: String
        public let models: [ModelDescriptor]

        public init(id: ProviderID, displayName: String, models: [ModelDescriptor]) {
            self.id = id
            self.displayName = displayName
            self.models = models
        }
    }

    /// Configured providers with at least one model, in registry order.
    public var providers: [ProviderModels]
    /// Configured providers whose model list could not be loaded (offline, revoked key, …).
    public var unavailable: [ProviderID: ErrorPresentation]

    public init(providers: [ProviderModels] = [], unavailable: [ProviderID: ErrorPresentation] = [:]) {
        self.providers = providers
        self.unavailable = unavailable
    }

    /// No model can be offered.
    public var isEmpty: Bool { providers.allSatisfy(\.models.isEmpty) }

    public func descriptor(for selection: ModelSelection) -> ModelDescriptor? {
        providers.first { $0.id == selection.providerID }?.models.first { $0.id == selection.modelID }
    }

    public func contains(_ selection: ModelSelection) -> Bool {
        descriptor(for: selection) != nil
    }
}
