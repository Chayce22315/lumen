import Foundation
import LumenFoundation

/// One piece of a chat message.
///
/// `thinking` and `redactedThinking` carry a provider's reasoning state. They are replayed to the
/// provider unchanged within the turn that produced them (Anthropic requires this to continue a
/// tool loop with its reasoning intact) and are never persisted or shown: the engine strips them
/// before saving a message.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// Reasoning text (often empty when the provider omits it) and its opaque signature.
    case thinking(text: String, signature: String?)
    /// Encrypted reasoning the provider returns instead of text.
    case redactedThinking(data: String)

    public var isReasoning: Bool {
        switch self {
        case .thinking, .redactedThinking: return true
        default: return false
        }
    }

    public var isToolResult: Bool {
        if case .toolResult = self { return true }
        return false
    }

    public var isToolUse: Bool {
        if case .toolUse = self { return true }
        return false
    }

    public var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

extension ContentBlock: Codable {
    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, toolUseID, content, isError, signature, data
    }

    enum Kind: String, Codable {
        case text
        case toolUse = "tool_use"
        case toolResult = "tool_result"
        case thinking
        case redactedThinking = "redacted_thinking"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
            )
        case .toolResult:
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? "",
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        case .thinking:
            self = .thinking(
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                signature: try container.decodeIfPresent(String.self, forKey: .signature)
            )
        case .redactedThinking:
            self = .redactedThinking(data: try container.decode(String.self, forKey: .data))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode(Kind.toolUse, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode(Kind.toolResult, forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        case .thinking(let text, let signature):
            try container.encode(Kind.thinking, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode(Kind.redactedThinking, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }
}
