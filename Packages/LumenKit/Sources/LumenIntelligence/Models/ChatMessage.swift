import Foundation
import LumenFoundation

public enum MessageRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
}

public enum MessageStatus: String, Sendable, Codable, Hashable {
    case complete
    /// Still being generated. Only ever seen in memory; messages are persisted once they settle.
    case streaming
    case failed
    case cancelled
}

/// A message in a conversation. Tool results travel in `user` messages, mirroring the provider
/// wire format, so a persisted transcript can be replayed as-is.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public typealias ID = Identifier<ChatMessage>

    public let id: ID
    public var conversationID: Conversation.ID
    public var role: MessageRole
    public var blocks: [ContentBlock]
    public var status: MessageStatus
    public var createdAt: Date
    /// Tokens the completion that produced this message consumed (assistant messages only).
    public var usage: TokenUsage?
    /// A user-presentable explanation when `status` is `.failed`.
    public var errorMessage: String?
    /// The model that produced this message (assistant messages only).
    public var model: ModelSelection?

    public init(
        id: ID = ID(),
        conversationID: Conversation.ID,
        role: MessageRole,
        blocks: [ContentBlock],
        status: MessageStatus = .complete,
        createdAt: Date,
        usage: TokenUsage? = nil,
        errorMessage: String? = nil,
        model: ModelSelection? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.blocks = blocks
        self.status = status
        self.createdAt = createdAt
        self.usage = usage
        self.errorMessage = errorMessage
        self.model = model
    }

    /// The visible text of the message (text blocks joined).
    public var text: String {
        blocks.compactMap(\.textValue).joined()
    }

    /// Tool calls requested by this message, in order.
    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { block in
            if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
            return nil
        }
    }

    /// True for a user message that carries anything other than tool results: it starts a turn.
    public var startsTurn: Bool {
        role == .user && !(blocks.allSatisfy(\.isToolResult) && !blocks.isEmpty)
    }

    /// The message without provider reasoning blocks (the persisted and displayed form).
    public func removingReasoning() -> ChatMessage {
        var copy = self
        copy.blocks.removeAll(where: \.isReasoning)
        return copy
    }

    /// The message without tool calls (used when calls are abandoned and must not be replayed unanswered).
    public func removingToolUses() -> ChatMessage {
        var copy = self
        copy.blocks.removeAll(where: \.isToolUse)
        return copy
    }

    public var reference: EntityReference {
        EntityReference(kind: .chatMessage, id: id)
    }
}

extension ChatMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case id, conversationID, role, blocks, status, createdAt, usage, errorMessage, model
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            conversationID: try container.decode(Conversation.ID.self, forKey: .conversationID),
            role: try container.decode(MessageRole.self, forKey: .role),
            blocks: try container.decodeIfPresent([ContentBlock].self, forKey: .blocks) ?? [],
            status: try container.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .complete,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            usage: try container.decodeIfPresent(TokenUsage.self, forKey: .usage),
            errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
            model: try container.decodeIfPresent(ModelSelection.self, forKey: .model)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(role, forKey: .role)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(model, forKey: .model)
    }
}
