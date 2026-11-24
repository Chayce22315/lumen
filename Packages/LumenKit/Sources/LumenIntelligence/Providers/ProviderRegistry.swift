import Foundation
import Synchronization

/// The configured model providers, in registration order.
///
/// The composition root registers providers at launch and whenever the user adds or removes a
/// local server; registering an existing `id` replaces that provider in place.
public final class ProviderRegistry: Sendable {
    private let state = Mutex<[any ModelProvider]>([])

    public init(_ providers: [any ModelProvider] = []) {
        for provider in providers {
            register(provider)
        }
    }

    public func register(_ provider: any ModelProvider) {
        state.withLock { providers in
            if let index = providers.firstIndex(where: { $0.id == provider.id }) {
                providers[index] = provider
            } else {
                providers.append(provider)
            }
        }
    }

    public func unregister(_ id: ProviderID) {
        state.withLock { providers in
            providers.removeAll { $0.id == id }
        }
    }

    public var providers: [any ModelProvider] {
        state.withLock { $0 }
    }

    public func provider(_ id: ProviderID) -> (any ModelProvider)? {
        state.withLock { providers in providers.first { $0.id == id } }
    }
}
