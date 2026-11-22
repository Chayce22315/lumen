import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for collections (`knowledge_collections`). `save` / `delete` record changes;
/// `upsertRow` / `deleteRow` (for the sync engine) do not.
public struct CollectionRepository {
    private let db: DatabaseConnection

    public init(_ db: DatabaseConnection) {
        self.db = db
    }

    public func collection(_ id: NoteCollection.ID) throws -> NoteCollection? {
        try db.queryFirst("SELECT * FROM knowledge_collections WHERE id = ?", [id]).map(NoteCollection.init(row:))
    }

    public func allCollections() throws -> [NoteCollection] {
        try db.query("SELECT * FROM knowledge_collections ORDER BY sort_order, name, id").map(NoteCollection.init(row:))
    }

    /// Direct children of `parentID` (`nil`: top-level collections), in display order.
    public func children(of parentID: NoteCollection.ID?) throws -> [NoteCollection] {
        let rows: [Row]
        if let parentID {
            rows = try db.query("SELECT * FROM knowledge_collections WHERE parent_id = ?", [parentID])
        } else {
            rows = try db.query("SELECT * FROM knowledge_collections WHERE parent_id IS NULL")
        }
        return try rows.map(NoteCollection.init(row:)).sorted(by: CollectionHierarchy.areInDisplayOrder)
    }

    /// The sort order that places a new child of `parentID` after its existing children.
    public func nextSortOrder(in parentID: NoteCollection.ID?) throws -> Int {
        let next: Int?
        if let parentID {
            next = try db.scalar("SELECT coalesce(max(sort_order) + 1, 0) FROM knowledge_collections WHERE parent_id = ?", [parentID])
        } else {
            next = try db.scalar("SELECT coalesce(max(sort_order) + 1, 0) FROM knowledge_collections WHERE parent_id IS NULL")
        }
        return next ?? 0
    }

    public func upsertRow(_ collection: NoteCollection) throws {
        try db.execute(KnowledgeSQL.upsert(into: "knowledge_collections", columns: NoteCollection.columns), collection.databaseArguments)
    }

    public func deleteRow(_ id: NoteCollection.ID) throws {
        try db.execute("DELETE FROM knowledge_collections WHERE id = ?", [id])
    }

    public func save(_ collection: NoteCollection) throws {
        try db.transaction {
            try upsertRow(collection)
            try db.recordUpsert(collection.reference, snapshot: collection)
        }
    }

    public func delete(_ id: NoteCollection.ID) throws {
        try db.transaction {
            try deleteRow(id)
            try db.recordDeletion(EntityReference(kind: .collection, id: id))
        }
    }
}
