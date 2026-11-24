import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenIntelligence
import LumenApplication

/// Settings › Assistant: provider keys (Keychain only), model choice, memory and tool approval.
@MainActor
@Observable
public final class AssistantSetupViewModel {
    public struct ProviderRow: Sendable, Hashable, Identifiable {
        public let id: ProviderID
        public let displayName: String
        public let requiresAPIKey: Bool
        public let hasAPIKey: Bool
    }

    public private(set) var providers: [ProviderRow] = []
    public private(set) var models: [ProviderID: [ModelDescriptor]] = [:]
    public private(set) var modelErrors: [ProviderID: ErrorPresentation] = [:]
    public private(set) var selection: ModelSelection?
    public private(set) var memoryEnabled = true
    public private(set) var requiresApproval = true
    public private(set) var memories: [MemoryItem] = []
    public private(set) var isLoadingModels = false
    /// Never displayed back; cleared after saving.
    public var apiKeyDraft = ""

    private let services: LumenServices

    public init(services: LumenServices) {
        self.services = services
    }

    public var isConfigured: Bool {
        guard let selection, let row = providers.first(where: { $0.id == selection.providerID }) else { return false }
        return !row.requiresAPIKey || row.hasAPIKey
    }

    public func load() async {
        let intelligence = services.intelligence
        providers = intelligence.providers.providers.map { provider in
            ProviderRow(
                id: provider.id,
                displayName: provider.displayName,
                requiresAPIKey: provider.requiresAPIKey,
                hasAPIKey: ((try? services.secrets.secret(for: provider.id.apiKeySecret)) ?? nil)?.nonBlank != nil
            )
        }
        selection = await services.settings.value(AssistantSettings.defaultModel)
        memoryEnabled = await intelligence.memory.isMemoryEnabled()
        requiresApproval = await services.settings.value(AssistantSettings.requireApprovalForMutatingTools)
        do {
            memories = try await intelligence.memory.memories()
        } catch {
            services.errors.report(error, context: "Loading memories")
        }
    }

    /// Stores the drafted key in the Keychain and clears the draft.
    public func saveAPIKey(for provider: ProviderID) async {
        guard let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank else { return }
        do {
            try services.secrets.setSecret(key, for: provider.apiKeySecret)
            apiKeyDraft = ""
            await services.intelligence.models.invalidate(provider)
            await load()
            await loadModels(for: provider)
        } catch {
            services.errors.report(error, context: "Saving the API key")
        }
    }

    public func removeAPIKey(for provider: ProviderID) async {
        do {
            try services.secrets.removeSecret(for: provider.apiKeySecret)
            await services.intelligence.models.invalidate(provider)
            await load()
        } catch {
            services.errors.report(error, context: "Removing the API key")
        }
    }

    public func loadModels(for provider: ProviderID) async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models[provider] = try await services.intelligence.models.models(for: provider, refresh: true)
            modelErrors[provider] = nil
        } catch {
            modelErrors[provider] = ErrorPresentation.from(error)
        }
    }

    public func select(_ model: ModelDescriptor) async {
        let selection = ModelSelection(providerID: model.providerID, modelID: model.id)
        do {
            try await services.settings.set(selection, for: AssistantSettings.defaultModel)
            self.selection = selection
        } catch {
            services.errors.report(error, context: "Choosing a model")
        }
    }

    public func setMemoryEnabled(_ enabled: Bool) async {
        do {
            try await services.intelligence.memory.setMemoryEnabled(enabled)
            memoryEnabled = enabled
        } catch {
            services.errors.report(error, context: "Changing memory")
        }
    }

    public func setRequiresApproval(_ required: Bool) async {
        do {
            try await services.settings.set(required, for: AssistantSettings.requireApprovalForMutatingTools)
            requiresApproval = required
        } catch {
            services.errors.report(error, context: "Changing tool approval")
        }
    }

    public func addMemory(_ content: String) async {
        guard let content = content.collapsingWhitespace.nonBlank else { return }
        await perform("Adding a memory") { _ = try await $0.add(content) }
    }

    public func setMemory(_ memory: MemoryItem, enabled: Bool) async {
        await perform("Updating a memory") { _ = try await $0.setEnabled(enabled, for: memory.id) }
    }

    public func deleteMemory(_ memory: MemoryItem) async {
        await perform("Deleting a memory") { try await $0.delete(memory.id) }
    }

    public func clearMemories() async {
        await perform("Clearing memories") { try await $0.clearAll() }
    }

    private func perform(_ context: String, _ work: (MemoryStore) async throws -> Void) async {
        do {
            try await work(services.intelligence.memory)
            memories = try await services.intelligence.memory.memories()
        } catch {
            services.errors.report(error, context: context)
        }
    }
}
