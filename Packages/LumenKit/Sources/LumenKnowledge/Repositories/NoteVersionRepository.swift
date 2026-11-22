import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for note version history (`knowledge_note_versions`). Versions are device-local and have no
/// change records.
public struct NoteVersionRepository {
    private let db: DatabaseConnection

    public init(_ db: DatabaseConnection) {
        self.db = db
    }

    public func version(_ id: NoteVersion.ID) throws -> NoteVersion? {
        try db.queryFirst("SELECT * FROM knowledge_note_versions WHERE id = ?", [id]).map(NoteVersion.init(row:))
    }

    /// Versions of a note, newest first (insertion order breaks ties).
    public func versions(of noteID: Note.ID) throws -> [NoteVersion] {
        try db.query(
            "SELECT * FROM knowledge_note_versions WHERE note_id = ? ORDER BY saved_at DESC, rowid DESC",
            [noteID]
        ).map(NoteVersion.init(row:))
    }

    public func latestVersion(of noteID: Note.ID) throws -> NoteVersion? {
        try db.queryFirst(
            "SELECT * FROM knowledge_note_versions WHERE note_id = ? ORDER BY saved_at DESC, rowid DESC LIMIT 1",
            [noteID]
        ).map(NoteVersion.init(row:))
    }

    public func insert(_ version: NoteVersion) throws {
        try db.execute(
            "INSERT INTO knowledge_note_versions (id, note_id, title, body, saved_at) VALUES (?, ?, ?, ?, ?)",
            [version.id, version.noteID, version.title, version.body, version.savedAt]
        )
    }

    public func delete(_ ids: [NoteVersion.ID]) throws {
        for id in ids {
            try db.execute("DELETE FROM knowledge_note_versions WHERE id = ?", [id])
        }
    }

    public func deleteAll(of noteID: Note.ID) throws {
        try db.execute("DELETE FROM knowledge_note_versions WHERE note_id = ?", [noteID])
    }
}
