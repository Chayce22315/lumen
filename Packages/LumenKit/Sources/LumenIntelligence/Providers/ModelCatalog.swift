import Foundation
import LumenFoundation

/// Caches each provider's model list.
///
/// Lists are fetched on first use, reused for `maxAge` seconds and refreshed on demand.
/// Concurrent requests for the same provider share one fetch.
public actor ModelCatalog {
    private struct Entry {
        let models: [ModelDescriptor]
        let fetchedAt: Date
    }

    private let registry: ProviderRegistry
    private let timeSource: any TimeSource
    private let maxAge: TimeInterval
    private let logger: Logger
    private var cache: [ProviderID: Entry] = [:]
    private var inFlight: [ProviderID: Task<[ModelDescriptor], any Error>] = [:]

    public init(registry: ProviderRegistry, timeSource: any TimeSource, maxAge: TimeInterval = 6 * 3_600, logger: Logger = .disabled()) {
        self.registry = registry
        self.timeSource = timeSource
        self.maxAge = max(0, maxAge)
        self.logger = logger
    }

    /// The provider's models, from cache when fresh.
    public func models(for providerID: ProviderID, refresh: Bool = false) async throws -> [ModelDescriptor] {
        guard let provider = registry.provider(providerID) else {
            throw AssistantError.providerUnavailable(providerID)
        }
        let now = timeSource.now()
        if !refresh, let entry = cache[providerID], now.timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.models
        }
        if let pending = inFlight[providerID] {
            return try await pending.value
        }
        let task = Task { try await provider.availableModels() }
        inFlight[providerID] = task
        do {
            let models = try await task.value
            inFlight[providerID] = nil
            cache[providerID] = Entry(models: models, fetchedAt: timeSource.now())
            logger.info("Model list refreshed", metadata: ["provider": providerID.rawValue, "count": String(models.count)])
            return models
        } catch {
            inFlight[providerID] = nil
            logger.warning("Model list unavailable", metadata: ["provider": providerID.rawValue, "error": Self.errorKind(error)])
            throw error
        }
    }

    /// Every registered provider's models; a provider whose list failed maps to its error.
    public func allModels(refresh: Bool = false) async -> [ProviderID: Result<[ModelDescriptor], any Error>] {
        var results: [ProviderID: Result<[ModelDescriptor], any Error>] = [:]
        for provider in registry.providers {
            do {
                results[provider.id] = .success(try await models(for: provider.id, refresh: refresh))
            } catch {
                results[provider.id] = .failure(error)
            }
        }
        return results
    }

    /// The descriptor for `selection`, or `nil` when its provider doesn't list it (or listing failed;
    /// the failure is logged by `models(for:)`).
    public func descriptor(for selection: ModelSelection) async -> ModelDescriptor? {
        do {
            return try await models(for: selection.providerID).first { $0.id == selection.modelID }
        } catch {
            return nil
        }
    }

    /// Drops cached lists (all providers when `providerID` is `nil`), e.g. after a key changes.
    public func invalidate(_ providerID: ProviderID? = nil) {
        if let providerID {
            cache[providerID] = nil
        } else {
            cache.removeAll()
        }
    }

    private static func errorKind(_ error: any Error) -> String {
        (error as? ProviderError)?.kind ?? String(describing: type(of: error))
    }
}
