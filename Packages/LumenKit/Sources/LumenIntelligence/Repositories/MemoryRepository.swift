import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for memories. `save`/`delete` also record the change for sync; `upsertRow`/`deleteRow`
/// write the row only (for the sync engine).
public enum MemoryRepository {
    public static func save(_ memory: MemoryItem, in db: DatabaseConnection) throws {
        try upsertRow(memory, in: db)
        try db.recordUpsert(memory.reference, snapshot: memory)
    }

    public static func delete(_ id: MemoryItem.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .memory, id: id))
    }

    public static func upsertRow(_ memory: MemoryItem, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO intelligence_memories (id, content, source, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content = excluded.content,
                source = excluded.source,
                is_enabled = excluded.is_enabled,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
            [memory.id, memory.content, memory.source, memory.isEnabled, memory.createdAt, memory.updatedAt]
        )
    }

    public static func deleteRow(_ id: MemoryItem.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM intelligence_memories WHERE id = ?", [id])
    }

    public static func fetch(_ id: MemoryItem.ID, in db: DatabaseConnection) throws -> MemoryItem? {
        try db.queryFirst("SELECT * FROM intelligence_memories WHERE id = ?", [id]).map(MemoryItem.init(row:))
    }

    /// Oldest first.
    public static func all(includeDisabled: Bool, in db: DatabaseConnection) throws -> [MemoryItem] {
        let sql = includeDisabled
            ? "SELECT * FROM intelligence_memories ORDER BY created_at, rowid"
            : "SELECT * FROM intelligence_memories WHERE is_enabled = 1 ORDER BY created_at, rowid"
        return try db.query(sql).map(MemoryItem.init(row:))
    }
}
