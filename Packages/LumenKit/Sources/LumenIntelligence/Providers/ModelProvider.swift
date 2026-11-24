import Foundation
import LumenFoundation

/// A message in the provider-neutral wire transcript, derived from persisted `ChatMessage`s by
/// `WireTranscript` (failed messages removed, roles alternating, tool calls paired with results).
public struct WireMessage: Sendable, Hashable {
    public var role: MessageRole
    public var blocks: [ContentBlock]

    public init(role: MessageRole, blocks: [ContentBlock]) {
        self.role = role
        self.blocks = blocks
    }
}

/// One completion request, independent of any provider's wire format.
public struct CompletionRequest: Sendable, Hashable {
    public var model: String
    public var system: String
    public var messages: [WireMessage]
    public var tools: [ToolDefinition]
    public var toolChoice: ToolChoice
    public var maxTokens: Int
    /// Sampling temperature for providers that accept one. The Anthropic provider never sends it:
    /// API version 2026-10-21 rejects every sampling parameter.
    public var temperature: Double?

    public init(
        model: String,
        system: String,
        messages: [WireMessage],
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxTokens: Int,
        temperature: Double? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// Why a completion ended.
public enum StopReason: Sendable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    /// The provider declined to answer (safety classifiers, content filters).
    case refusal
    case other(String)
}

/// One step of a streamed completion.
public enum CompletionEvent: Sendable, Hashable {
    case textDelta(String)
    /// A complete reasoning block (emitted when the block ends).
    case thinking(text: String, signature: String?)
    case redactedThinking(data: String)
    /// A tool call, emitted once its input JSON is complete.
    case toolUse(id: String, name: String, input: JSONValue)
    /// A tool call whose input was not a valid JSON object (truncated or malformed).
    case invalidToolUse(id: String, name: String, rawInput: String)
    /// Cumulative usage for this completion so far; the last value wins.
    case usage(TokenUsage)
    case stop(StopReason)
}

/// A source of models: Anthropic, OpenAI, or any OpenAI-compatible server.
///
/// `stream` must honour cancellation: when the consuming task is cancelled or stops iterating,
/// the underlying HTTP request is cancelled.
public protocol ModelProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var requiresAPIKey: Bool { get }
    func availableModels() async throws -> [ModelDescriptor]
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error>
}
