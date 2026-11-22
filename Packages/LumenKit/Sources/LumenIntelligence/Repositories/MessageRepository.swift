import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for chat messages. `save`/`delete` also record the change for sync; `upsertRow`/`deleteRow`
/// write the row only (for the sync engine).
public enum MessageRepository {
    public static func save(_ message: ChatMessage, in db: DatabaseConnection) throws {
        try upsertRow(message, in: db)
        try db.recordUpsert(message.reference, snapshot: message)
    }

    public static func delete(_ id: ChatMessage.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .chatMessage, id: id))
    }

    /// Deletes every message of a conversation, recording each deletion.
    public static func deleteAll(in conversationID: Conversation.ID, db: DatabaseConnection) throws {
        let ids = try db.query("SELECT id FROM intelligence_messages WHERE conversation_id = ?", [conversationID])
            .map { try $0.get("id", as: ChatMessage.ID.self) }
        for id in ids {
            try delete(id, in: db)
        }
    }

    public static func upsertRow(_ message: ChatMessage, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO intelligence_messages
                (id, conversation_id, role, blocks, status, created_at, usage, error_message, provider_id, model_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversation_id = excluded.conversation_id,
                role = excluded.role,
                blocks = excluded.blocks,
                status = excluded.status,
                created_at = excluded.created_at,
                usage = excluded.usage,
                error_message = excluded.error_message,
                provider_id = excluded.provider_id,
                model_id = excluded.model_id
            """,
            [
                message.id, message.conversationID, message.role, JSONColumn(message.blocks), message.status,
                message.createdAt, message.usage.map(JSONColumn.init), message.errorMessage,
                message.model?.providerID, message.model?.modelID,
            ]
        )
    }

    public static func deleteRow(_ id: ChatMessage.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM intelligence_messages WHERE id = ?", [id])
    }

    public static func fetch(_ id: ChatMessage.ID, in db: DatabaseConnection) throws -> ChatMessage? {
        try db.queryFirst("SELECT * FROM intelligence_messages WHERE id = ?", [id]).map(ChatMessage.init(row:))
    }

    /// The conversation's messages, oldest first. Ties (same timestamp) keep insertion order.
    public static func messages(in conversationID: Conversation.ID, db: DatabaseConnection) throws -> [ChatMessage] {
        try db.query(
            "SELECT * FROM intelligence_messages WHERE conversation_id = ? ORDER BY created_at, rowid",
            [conversationID]
        ).map(ChatMessage.init(row:))
    }

    /// The newest message timestamp in the conversation.
    public static func latestCreatedAt(in conversationID: Conversation.ID, db: DatabaseConnection) throws -> Date? {
        // `max` over no rows is NULL, so the column is read as optional.
        let latest = try db.scalar("SELECT max(created_at) FROM intelligence_messages WHERE conversation_id = ?", [conversationID], as: Date?.self)
        return latest ?? nil
    }
}
