import Foundation
import LumenFoundation

/// Tokens consumed by one completion. Device-local (not synchronized): it describes what this
/// device spent with each provider.
public struct UsageRecord: Sendable, Hashable {
    public var providerID: ProviderID
    public var modelID: String
    public var conversationID: Conversation.ID?
    public var messageID: ChatMessage.ID?
    public var usage: TokenUsage
    public var recordedAt: Date

    public init(
        providerID: ProviderID,
        modelID: String,
        conversationID: Conversation.ID? = nil,
        messageID: ChatMessage.ID? = nil,
        usage: TokenUsage,
        recordedAt: Date
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.conversationID = conversationID
        self.messageID = messageID
        self.usage = usage
        self.recordedAt = recordedAt
    }
}

/// How usage totals are bucketed.
public enum UsageGrouping: String, Sendable, Hashable, CaseIterable {
    case day
    case model
    case provider
}

/// Summed usage for one bucket. Only the key fields of the requested grouping are set
/// (`model` sets both `providerID` and `modelID`).
public struct UsageTotal: Sendable, Hashable {
    public var day: CalendarDate?
    public var providerID: ProviderID?
    public var modelID: String?
    public var usage: TokenUsage
    /// Number of completions in the bucket.
    public var completions: Int

    public init(day: CalendarDate? = nil, providerID: ProviderID? = nil, modelID: String? = nil, usage: TokenUsage, completions: Int) {
        self.day = day
        self.providerID = providerID
        self.modelID = modelID
        self.usage = usage
        self.completions = completions
    }
}
