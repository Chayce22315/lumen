import Foundation
import LumenFoundation

/// A conversation found by `ConversationService.search(_:limit:)`.
public struct ConversationSearchHit: Sendable, Hashable, Identifiable {
    public var conversation: Conversation
    /// The title contains every search term.
    public var titleMatches: Bool
    /// The best-matching message, when a message matched.
    public var matchedMessageID: ChatMessage.ID?
    /// That message's visible text, for building a snippet.
    public var matchedText: String?

    public init(conversation: Conversation, titleMatches: Bool, matchedMessageID: ChatMessage.ID? = nil, matchedText: String? = nil) {
        self.conversation = conversation
        self.titleMatches = titleMatches
        self.matchedMessageID = matchedMessageID
        self.matchedText = matchedText
    }

    public var id: Conversation.ID { conversation.id }
}
