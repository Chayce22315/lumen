import Foundation
import LumenCore

/// Identifies a model provider ("anthropic", "openai", "ollama"). Persisted in conversations,
/// settings and usage records, so raw values never change once shipped.
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let anthropic: ProviderID = "anthropic"
    public static let openAI: ProviderID = "openai"

    /// Where this provider's API key lives in the `SecretStore`. Keys never touch SQLite or settings.
    public var apiKeySecret: SecretKey { SecretKey("intelligence.provider.\(rawValue).apiKey") }
}

extension ProviderID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension ProviderID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// A model a provider offers, with the limits the engine budgets context against.
public struct ModelDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// The provider's model identifier, sent verbatim in requests.
    public var id: String
    public var displayName: String
    public var providerID: ProviderID
    /// Maximum input tokens, when the provider reports it.
    public var contextWindow: Int?
    /// Maximum output tokens per response, when the provider reports it.
    public var maxOutputTokens: Int?
    public var supportsTools: Bool

    public init(
        id: String,
        displayName: String,
        providerID: ProviderID,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
    }

    public var selection: ModelSelection { ModelSelection(providerID: providerID, modelID: id) }
}

/// Which model answers: a provider plus one of its model identifiers.
public struct ModelSelection: Sendable, Hashable, Codable {
    public var providerID: ProviderID
    public var modelID: String

    public init(providerID: ProviderID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}
