import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Conversation management: create, rename, archive, pin, delete, list and read messages.
/// Messages themselves are written by `AssistantEngine`.
public final class ConversationService: Sendable {
    public static let maximumTitleLength = 200

    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger

    public init(database: Database, events: EventBus, timeSource: any TimeSource, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
    }

    @discardableResult
    public func create(title: String = "", selection: ModelSelection? = nil, context: ActionContext = .user) async throws -> Conversation {
        let conversation = Conversation(title: try Self.normalizedTitle(title), selection: selection, createdAt: timeSource.now())
        try await database.write { db in try ConversationRepository.save(conversation, in: db) }
        events.publish(context.event(IntelligenceEvents.conversationCreated, entity: conversation.reference, at: conversation.createdAt))
        return conversation
    }

    public func conversation(_ id: Conversation.ID) async throws -> Conversation? {
        try await database.read { db in try ConversationRepository.fetch(id, in: db) }
    }

    /// Pinned conversations first, then the most recently active.
    public func list(includeArchived: Bool = false) async throws -> [Conversation] {
        try await database.read { db in try ConversationRepository.list(includeArchived: includeArchived, in: db) }
    }

    /// Messages oldest first, as stored (no provider reasoning blocks).
    public func messages(in conversationID: Conversation.ID) async throws -> [ChatMessage] {
        try await database.read { db in try MessageRepository.messages(in: conversationID, db: db) }
    }

    /// Renames the conversation; an empty title makes it untitled again.
    @discardableResult
    public func rename(_ id: Conversation.ID, to title: String, context: ActionContext = .user) async throws -> Conversation {
        let normalized = try Self.normalizedTitle(title)
        let renamed = try await update(id) { $0.title = normalized }
        events.publish(context.event(IntelligenceEvents.conversationRenamed, entity: renamed.reference, attributes: ["automatic": false], at: timeSource.now()))
        return renamed
    }

    @discardableResult
    public func setArchived(_ isArchived: Bool, for id: Conversation.ID) async throws -> Conversation {
        try await update(id) { $0.isArchived = isArchived }
    }

    @discardableResult
    public func setPinned(_ isPinned: Bool, for id: Conversation.ID) async throws -> Conversation {
        try await update(id) { $0.isPinned = isPinned }
    }

    /// Sets the conversation's model; `nil` follows the default model setting.
    @discardableResult
    public func setSelection(_ selection: ModelSelection?, for id: Conversation.ID, context: ActionContext = .user) async throws -> Conversation {
        let updated = try await update(id) { $0.selection = selection }
        var attributes: [String: JSONValue] = ["followsDefault": .bool(selection == nil)]
        if let selection {
            attributes["provider"] = .string(selection.providerID.rawValue)
        }
        events.publish(context.event(IntelligenceEvents.conversationModelChanged, entity: updated.reference, attributes: attributes, at: timeSource.now()))
        return updated
    }

    // MARK: - Search

    /// Conversations whose title or messages contain every term of `query` (prefix matching,
    /// case- and diacritic-insensitive). Title matches come first, then conversations matched by
    /// a message; each group is ordered by relevance. Archived conversations are included.
    public func search(_ query: String, limit: Int = 30) async throws -> [ConversationSearchHit] {
        guard let expression = ConversationSearchIndex.matchExpression(for: query) else { return [] }
        let limit = max(1, limit)
        return try await database.read { db in
            var hits: [Conversation.ID: ConversationSearchHit] = [:]
            var order: [Conversation.ID] = []

            let titleRows = try db.query(
                """
                SELECT intelligence_conversations.* FROM intelligence_conversation_search
                JOIN intelligence_conversations ON intelligence_conversations.rowid = intelligence_conversation_search.rowid
                WHERE intelligence_conversation_search MATCH ?
                ORDER BY bm25(intelligence_conversation_search)
                LIMIT ?
                """,
                [expression, limit]
            )
            for row in titleRows {
                let conversation = try Conversation(row: row)
                hits[conversation.id] = ConversationSearchHit(conversation: conversation, titleMatches: true)
                order.append(conversation.id)
            }

            // The best message per conversation; more rows than `limit` because several can
            // belong to the same conversation.
            let messageRows = try db.query(
                """
                SELECT intelligence_messages.id AS message_id, intelligence_messages.conversation_id AS conversation_id,
                       intelligence_message_search.text AS text
                FROM intelligence_message_search
                JOIN intelligence_messages ON intelligence_messages.rowid = intelligence_message_search.rowid
                WHERE intelligence_message_search MATCH ?
                ORDER BY bm25(intelligence_message_search)
                LIMIT ?
                """,
                [expression, limit * 20]
            )
            for row in messageRows {
                let conversationID: Conversation.ID = try row.get("conversation_id")
                let messageID: ChatMessage.ID = try row.get("message_id")
                let text: String = try row.get("text")
                if var hit = hits[conversationID] {
                    if hit.matchedMessageID == nil {
                        hit.matchedMessageID = messageID
                        hit.matchedText = text
                        hits[conversationID] = hit
                    }
                    continue
                }
                guard order.count < limit, let conversation = try ConversationRepository.fetch(conversationID, in: db) else { continue }
                hits[conversationID] = ConversationSearchHit(conversation: conversation, titleMatches: false, matchedMessageID: messageID, matchedText: text)
                order.append(conversationID)
            }
            return order.compactMap { hits[$0] }
        }
    }

    /// Deletes the conversation and all its messages (every deletion is recorded for sync).
    public func delete(_ id: Conversation.ID, context: ActionContext = .user) async throws {
        let existed = try await database.write { db -> Bool in
            guard try ConversationRepository.fetch(id, in: db) != nil else { return false }
            try MessageRepository.deleteAll(in: id, db: db)
            try ConversationRepository.delete(id, in: db)
            return true
        }
        guard existed else { throw DatabaseError.notFound(EntityReference(kind: .conversation, id: id)) }
        events.publish(context.event(IntelligenceEvents.conversationDeleted, entity: EntityReference(kind: .conversation, id: id), at: timeSource.now()))
        logger.info("Conversation deleted")
    }

    private func update(_ id: Conversation.ID, _ change: @escaping @Sendable (inout Conversation) -> Void) async throws -> Conversation {
        let updated = try await database.write { db -> Conversation? in
            guard var conversation = try ConversationRepository.fetch(id, in: db) else { return nil }
            change(&conversation)
            try ConversationRepository.save(conversation, in: db)
            return conversation
        }
        guard let updated else { throw DatabaseError.notFound(EntityReference(kind: .conversation, id: id)) }
        return updated
    }

    static func normalizedTitle(_ title: String) throws -> String {
        let collapsed = title.collapsingWhitespace
        guard collapsed.count <= maximumTitleLength else {
            throw ValidationError(field: "title", reason: "Keep titles under \(maximumTitleLength) characters.")
        }
        return collapsed
    }
}
