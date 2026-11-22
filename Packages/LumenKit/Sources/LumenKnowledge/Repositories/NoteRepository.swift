import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for notes (`knowledge_notes`).
///
/// `save` / `delete` record a change in the same transaction; `upsertRow` / `deleteRow` do not and
/// are meant for the sync engine applying remote changes. Both paths keep the derived link index
/// up to date, and deleting a note also removes its local version history.
public struct NoteRepository {
    private let db: DatabaseConnection

    public init(_ db: DatabaseConnection) {
        self.db = db
    }

    // MARK: - Reads

    public func note(_ id: Note.ID) throws -> Note? {
        try db.queryFirst("SELECT * FROM knowledge_notes WHERE id = ?", [id]).map(Note.init(row:))
    }

    public func exists(_ id: Note.ID) throws -> Bool {
        let count: Int? = try db.scalar("SELECT count(*) FROM knowledge_notes WHERE id = ?", [id])
        return (count ?? 0) > 0
    }

    public func notes(matching query: NoteQuery) throws -> [Note] {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let collectionID = query.collectionID {
            clauses.append("collection_id = ?")
            arguments.append(collectionID)
        }
        if let tag = query.tag {
            // A tag that normalizes to nothing matches no note.
            guard let normalized = TagNormalizer.normalize(tag) else { return [] }
            clauses.append("EXISTS (SELECT 1 FROM json_each(knowledge_notes.tags) WHERE json_each.value = ?)")
            arguments.append(normalized)
        }
        if !query.includeArchived {
            clauses.append("is_archived = 0")
        }
        if query.pinnedOnly {
            clauses.append("is_pinned = 1")
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        arguments.append(KnowledgeSQL.limitValue(query.limit))
        return try db.query(
            "SELECT * FROM knowledge_notes \(filter) \(KnowledgeSQL.orderClause(query.sort, table: "knowledge_notes")) LIMIT ?",
            arguments
        ).map(Note.init(row:))
    }

    /// Notes changed after `date` (archived included), oldest change first.
    public func notes(updatedSince date: Date) throws -> [Note] {
        try db.query("SELECT * FROM knowledge_notes WHERE updated_at > ? ORDER BY updated_at, id", [date]).map(Note.init(row:))
    }

    /// Every note, archived included, oldest first.
    public func allNotes() throws -> [Note] {
        try db.query("SELECT * FROM knowledge_notes ORDER BY created_at, id").map(Note.init(row:))
    }

    /// Notes directly in `collectionID` (`nil`: at the root), archived included.
    public func notes(inCollection collectionID: NoteCollection.ID?) throws -> [Note] {
        if let collectionID {
            return try db.query("SELECT * FROM knowledge_notes WHERE collection_id = ? ORDER BY created_at, id", [collectionID]).map(Note.init(row:))
        }
        return try db.query("SELECT * FROM knowledge_notes WHERE collection_id IS NULL ORDER BY created_at, id").map(Note.init(row:))
    }

    /// Notes carrying at least one of `tags` (already normalized).
    public func notes(taggedWithAny tags: [String]) throws -> [Note] {
        guard !tags.isEmpty else { return [] }
        return try db.query(
            """
            SELECT * FROM knowledge_notes
            WHERE EXISTS (SELECT 1 FROM json_each(knowledge_notes.tags) WHERE json_each.value IN (\(KnowledgeSQL.placeholders(tags.count))))
            ORDER BY created_at, id
            """,
            tags
        ).map(Note.init(row:))
    }

    /// The most recently updated note whose title has the given `LinkTitle.matchingKey`.
    public func mostRecentNote(withTitleKey key: String) throws -> Note? {
        guard !key.isEmpty else { return nil }
        return try db.queryFirst(
            "SELECT * FROM knowledge_notes WHERE title_key = ? ORDER BY updated_at DESC, id LIMIT 1",
            [key]
        ).map(Note.init(row:))
    }

    // MARK: - Writes

    /// Writes the row and refreshes the note's outgoing links. No change record.
    public func upsertRow(_ note: Note) throws {
        try db.execute(KnowledgeSQL.upsert(into: "knowledge_notes", columns: Note.columns), note.databaseArguments)
        try LinkRepository(db).refreshLinks(for: note)
    }

    /// Removes the row, its outgoing links and its versions, and turns `[[Title]]` links that
    /// pointed at it back into unresolved title links. No change record.
    public func deleteRow(_ id: Note.ID) throws {
        let reference = EntityReference(kind: .note, id: id)
        try db.execute("DELETE FROM knowledge_notes WHERE id = ?", [id])
        let links = LinkRepository(db)
        try links.deleteOutgoingLinks(from: reference)
        try links.unresolveLinks(targeting: reference)
        try NoteVersionRepository(db).deleteAll(of: id)
    }

    /// `upsertRow` plus a change record with the note's snapshot.
    public func save(_ note: Note) throws {
        try db.transaction {
            try upsertRow(note)
            try db.recordUpsert(note.reference, snapshot: note)
        }
    }

    /// `deleteRow` plus a deletion change record.
    public func delete(_ id: Note.ID) throws {
        try db.transaction {
            try deleteRow(id)
            try db.recordDeletion(EntityReference(kind: .note, id: id))
        }
    }
}
