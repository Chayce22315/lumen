import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for conversations. `save`/`delete` also record the change for sync; `upsertRow`/`deleteRow`
/// write the row only and are what the sync engine uses to apply remote changes.
public enum ConversationRepository {
    public static func save(_ conversation: Conversation, in db: DatabaseConnection) throws {
        try upsertRow(conversation, in: db)
        try db.recordUpsert(conversation.reference, snapshot: conversation)
    }

    public static func delete(_ id: Conversation.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .conversation, id: id))
    }

    public static func upsertRow(_ conversation: Conversation, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO intelligence_conversations
                (id, title, provider_id, model_id, created_at, updated_at, is_archived, is_pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                provider_id = excluded.provider_id,
                model_id = excluded.model_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                is_archived = excluded.is_archived,
                is_pinned = excluded.is_pinned
            """,
            [
                conversation.id, conversation.title, conversation.selection?.providerID, conversation.selection?.modelID,
                conversation.createdAt, conversation.updatedAt, conversation.isArchived, conversation.isPinned,
            ]
        )
    }

    public static func deleteRow(_ id: Conversation.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM intelligence_conversations WHERE id = ?", [id])
    }

    public static func fetch(_ id: Conversation.ID, in db: DatabaseConnection) throws -> Conversation? {
        try db.queryFirst("SELECT * FROM intelligence_conversations WHERE id = ?", [id]).map(Conversation.init(row:))
    }

    /// Pinned first, then most recently updated.
    public static func list(includeArchived: Bool, in db: DatabaseConnection) throws -> [Conversation] {
        let sql = includeArchived
            ? "SELECT * FROM intelligence_conversations ORDER BY is_pinned DESC, updated_at DESC, id"
            : "SELECT * FROM intelligence_conversations WHERE is_archived = 0 ORDER BY is_pinned DESC, updated_at DESC, id"
        return try db.query(sql).map(Conversation.init(row:))
    }
}
