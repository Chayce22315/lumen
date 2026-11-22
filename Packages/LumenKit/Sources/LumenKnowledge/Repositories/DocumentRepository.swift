import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for document metadata (`knowledge_documents`). File bytes are handled by `DocumentStorage`.
/// `save` / `delete` record changes; `upsertRow` / `deleteRow` (for the sync engine) do not.
public struct DocumentRepository {
    private let db: DatabaseConnection

    public init(_ db: DatabaseConnection) {
        self.db = db
    }

    public func document(_ id: DocumentItem.ID) throws -> DocumentItem? {
        try db.queryFirst("SELECT * FROM knowledge_documents WHERE id = ?", [id]).map(DocumentItem.init(row:))
    }

    public func documents(matching query: DocumentQuery) throws -> [DocumentItem] {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let collectionID = query.collectionID {
            clauses.append("collection_id = ?")
            arguments.append(collectionID)
        }
        if let tag = query.tag {
            guard let normalized = TagNormalizer.normalize(tag) else { return [] }
            clauses.append("EXISTS (SELECT 1 FROM json_each(knowledge_documents.tags) WHERE json_each.value = ?)")
            arguments.append(normalized)
        }
        if let contentType = query.contentType {
            clauses.append("content_type = ?")
            arguments.append(contentType)
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        arguments.append(KnowledgeSQL.limitValue(query.limit))
        return try db.query(
            "SELECT * FROM knowledge_documents \(filter) \(KnowledgeSQL.orderClause(query.sort, table: "knowledge_documents")) LIMIT ?",
            arguments
        ).map(DocumentItem.init(row:))
    }

    /// Every document, oldest first.
    public func allDocuments() throws -> [DocumentItem] {
        try db.query("SELECT * FROM knowledge_documents ORDER BY created_at, id").map(DocumentItem.init(row:))
    }

    /// Documents changed after `date`, oldest change first.
    public func documents(updatedSince date: Date) throws -> [DocumentItem] {
        try db.query("SELECT * FROM knowledge_documents WHERE updated_at > ? ORDER BY updated_at, id", [date]).map(DocumentItem.init(row:))
    }

    /// The earliest imported document with these bytes.
    public func firstDocument(withSHA256 sha256: String) throws -> DocumentItem? {
        try db.queryFirst(
            "SELECT * FROM knowledge_documents WHERE sha256 = ? ORDER BY created_at, id LIMIT 1",
            [sha256]
        ).map(DocumentItem.init(row:))
    }

    /// How many documents point at the file stored under `storageKey`.
    public func referenceCount(storageKey: String) throws -> Int {
        try db.scalar("SELECT count(*) FROM knowledge_documents WHERE storage_key = ?", [storageKey]) ?? 0
    }

    public func documents(inCollection collectionID: NoteCollection.ID?) throws -> [DocumentItem] {
        if let collectionID {
            return try db.query("SELECT * FROM knowledge_documents WHERE collection_id = ? ORDER BY created_at, id", [collectionID])
                .map(DocumentItem.init(row:))
        }
        return try db.query("SELECT * FROM knowledge_documents WHERE collection_id IS NULL ORDER BY created_at, id")
            .map(DocumentItem.init(row:))
    }

    /// Documents carrying at least one of `tags` (already normalized).
    public func documents(taggedWithAny tags: [String]) throws -> [DocumentItem] {
        guard !tags.isEmpty else { return [] }
        return try db.query(
            """
            SELECT * FROM knowledge_documents
            WHERE EXISTS (SELECT 1 FROM json_each(knowledge_documents.tags) WHERE json_each.value IN (\(KnowledgeSQL.placeholders(tags.count))))
            ORDER BY created_at, id
            """,
            tags
        ).map(DocumentItem.init(row:))
    }

    public func upsertRow(_ document: DocumentItem) throws {
        try db.execute(KnowledgeSQL.upsert(into: "knowledge_documents", columns: DocumentItem.columns), document.databaseArguments)
    }

    public func deleteRow(_ id: DocumentItem.ID) throws {
        try db.execute("DELETE FROM knowledge_documents WHERE id = ?", [id])
    }

    public func save(_ document: DocumentItem) throws {
        try db.transaction {
            try upsertRow(document)
            try db.recordUpsert(document.reference, snapshot: document)
        }
    }

    public func delete(_ id: DocumentItem.ID) throws {
        try db.transaction {
            try deleteRow(id)
            try db.recordDeletion(EntityReference(kind: .document, id: id))
        }
    }
}
