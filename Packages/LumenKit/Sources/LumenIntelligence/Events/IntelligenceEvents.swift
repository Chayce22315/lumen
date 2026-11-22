import Foundation
import LumenCore

/// Domain events published by the intelligence engine, always after the transaction commits.
///
/// Attributes are identifiers, tool names, outcomes and token counts only — never prompts,
/// message text or memory content.
public enum IntelligenceEvents {
    public static let conversationCreated: EventName = "intelligence.conversation.created"
    public static let conversationDeleted: EventName = "intelligence.conversation.deleted"
    public static let conversationRenamed: EventName = "intelligence.conversation.renamed"
    /// The conversation's model override was set or cleared (`followsDefault`).
    public static let conversationModelChanged: EventName = "intelligence.conversation.modelChanged"

    public static let messageCompleted: EventName = "intelligence.message.completed"
    public static let messageFailed: EventName = "intelligence.message.failed"
    public static let messageCancelled: EventName = "intelligence.message.cancelled"

    public static let toolExecuted: EventName = "intelligence.tool.executed"

    public static let memoryAdded: EventName = "intelligence.memory.added"
    public static let memoryUpdated: EventName = "intelligence.memory.updated"
    public static let memoryDeleted: EventName = "intelligence.memory.deleted"

    public static let all: [EventName] = [
        conversationCreated, conversationDeleted, conversationRenamed, conversationModelChanged,
        messageCompleted, messageFailed, messageCancelled,
        toolExecuted,
        memoryAdded, memoryUpdated, memoryDeleted,
    ]
}
