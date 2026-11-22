import Foundation
import LumenFoundation
import LumenPersistence

// Row ⇄ model mapping for the knowledge tables. Column order in the `columns` arrays matches the
// argument order produced by `databaseArguments`.

extension Note {
    static let columns = [
        "id", "title", "title_key", "body", "collection_id", "tags", "is_pinned", "is_archived", "created_at", "updated_at",
    ]

    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            title: try row.get("title"),
            body: try row.get("body"),
            collectionID: try row.get("collection_id"),
            tags: try row.json("tags", as: [String].self),
            isPinned: try row.get("is_pinned"),
            isArchived: try row.get("is_archived"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }

    var databaseArguments: [any DatabaseValueConvertible] {
        [id, title, LinkTitle.matchingKey(title), body, collectionID, JSONColumn(tags), isPinned, isArchived, createdAt, updatedAt]
    }
}

extension NoteCollection {
    static let columns = ["id", "name", "parent_id", "sort_order", "symbol_name", "created_at", "updated_at"]

    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            name: try row.get("name"),
            parentID: try row.get("parent_id"),
            sortOrder: try row.get("sort_order"),
            symbolName: try row.get("symbol_name"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }

    var databaseArguments: [any DatabaseValueConvertible] {
        [id, name, parentID, sortOrder, symbolName, createdAt, updatedAt]
    }
}

extension DocumentItem {
    static let columns = [
        "id", "title", "title_key", "original_file_name", "content_type", "byte_count", "sha256", "storage_key",
        "collection_id", "tags", "extracted_text", "created_at", "updated_at",
    ]

    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            title: try row.get("title"),
            originalFileName: try row.get("original_file_name"),
            contentType: try row.get("content_type"),
            byteCount: try row.get("byte_count"),
            sha256: try row.get("sha256"),
            storageKey: try row.get("storage_key"),
            collectionID: try row.get("collection_id"),
            tags: try row.json("tags", as: [String].self),
            extractedText: try row.get("extracted_text"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }

    var databaseArguments: [any DatabaseValueConvertible] {
        [
            id, title, LinkTitle.matchingKey(title), originalFileName, contentType, byteCount, sha256, storageKey,
            collectionID, JSONColumn(tags), extractedText, createdAt, updatedAt,
        ]
    }
}

extension NoteVersion {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            noteID: try row.get("note_id"),
            title: try row.get("title"),
            body: try row.get("body"),
            savedAt: try row.get("saved_at")
        )
    }
}

extension EntityLink {
    init(row: Row) throws {
        let kindText: String = try row.get("kind")
        guard let kind = Kind(rawValue: kindText) else {
            throw DatabaseError.typeMismatch(column: "kind", expected: "EntityLink.Kind", actual: kindText)
        }
        let targetKind: EntityKind? = try row.get("target_kind")
        let targetID: UUID? = try row.get("target_id")
        let target: EntityReference?
        if let targetKind, let targetID {
            target = EntityReference(kind: targetKind, id: targetID)
        } else {
            target = nil
        }
        self.init(
            source: EntityReference(kind: try row.get("source_kind"), id: try row.get("source_id", as: UUID.self)),
            position: try row.get("position"),
            target: target,
            targetTitle: try row.get("target_title"),
            label: try row.get("label"),
            kind: kind
        )
    }
}

/// SQL helpers shared by the repositories.
enum KnowledgeSQL {
    /// `INSERT … ON CONFLICT(id) DO UPDATE` over `columns`. An upsert rather than `REPLACE`, so the
    /// row keeps its rowid.
    static func upsert(into table: String, columns: [String]) -> String {
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.filter { $0 != "id" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        return "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)"
    }

    /// `?, ?, ?` for `count` values.
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(1, count)).joined(separator: ", ")
    }

    static func orderClause(_ sort: KnowledgeSort, table: String) -> String {
        switch sort {
        case .updated: return "ORDER BY \(table).updated_at DESC, \(table).id"
        case .created: return "ORDER BY \(table).created_at DESC, \(table).id"
        case .title: return "ORDER BY \(table).title_key ASC, \(table).id"
        }
    }

    /// SQLite treats a negative LIMIT as "no limit".
    static func limitValue(_ limit: Int?) -> Int {
        guard let limit else { return -1 }
        return max(0, limit)
    }
}
