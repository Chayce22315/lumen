import Foundation
import LumenFoundation
import LumenPersistence

extension NoteService {
    // MARK: - Notes

    public func note(_ id: Note.ID) async throws -> Note? {
        try await database.read { db in try NoteRepository(db).note(id) }
    }

    public func notes(query: NoteQuery = NoteQuery()) async throws -> [Note] {
        try await database.read { db in try NoteRepository(db).notes(matching: query) }
    }

    /// Most recently updated notes, archived ones excluded.
    public func recent(limit: Int = 20) async throws -> [Note] {
        try await notes(query: NoteQuery(sort: .updated, limit: max(0, limit)))
    }

    /// Notes changed after `date`, archived included, oldest change first (incremental indexing).
    public func notes(updatedSince date: Date) async throws -> [Note] {
        try await database.read { db in try NoteRepository(db).notes(updatedSince: date) }
    }

    /// Every note, archived included (full reindexing).
    public func allNotes() async throws -> [Note] {
        try await database.read { db in try NoteRepository(db).allNotes() }
    }

    // MARK: - Links

    /// The most recently updated note whose title matches `title` (case, diacritics and extra
    /// whitespace ignored). Titles need not be unique.
    public func resolveTitle(_ title: String) async throws -> Note? {
        let key = LinkTitle.matchingKey(title)
        return try await database.read { db in try NoteRepository(db).mostRecentNote(withTitleKey: key) }
    }

    /// Links written in the note, in order. `[[Title]]` links that were unresolved when the note was
    /// saved are resolved against the current titles, so a note created later is found.
    public func outgoingLinks(from noteID: Note.ID) async throws -> [EntityLink] {
        try await database.read { db in
            let notes = NoteRepository(db)
            var resolved: [String: EntityReference?] = [:]
            return try LinkRepository(db).outgoingLinks(from: EntityReference(kind: .note, id: noteID)).map { link in
                guard link.kind == .wikiLink, link.target == nil else { return link }
                let key = LinkTitle.matchingKey(link.targetTitle)
                var copy = link
                if let cached = resolved[key] {
                    copy.target = cached
                } else {
                    let target = try notes.mostRecentNote(withTitleKey: key)?.reference
                    resolved[key] = .some(target)
                    copy.target = target
                }
                return copy
            }
        }
    }

    /// Links pointing at `target`: links resolved to it and — when `target` is a note — unresolved
    /// `[[Title]]` links matching its title, provided it is the note that title resolves to (the
    /// most recently updated one with that title). Most recently updated source first.
    public func backlinks(to target: EntityReference) async throws -> [EntityLink] {
        try await database.read { db in
            var titleKey: String?
            if target.kind == .note, let note = try NoteRepository(db).note(target.identifier(as: Note.self)) {
                let key = LinkTitle.matchingKey(note.title)
                if try NoteRepository(db).mostRecentNote(withTitleKey: key)?.id == note.id {
                    titleKey = key
                }
            }
            return try LinkRepository(db).backlinks(to: target, unresolvedTitleKey: titleKey)
        }
    }

    /// The distinct notes that link to `target`, in `backlinks(to:)` order.
    public func backlinkingNotes(to target: EntityReference) async throws -> [Note] {
        let links = try await backlinks(to: target)
        var seen = Set<UUID>()
        let sourceIDs = links.compactMap { link -> Note.ID? in
            guard link.source.kind == .note, seen.insert(link.source.id).inserted else { return nil }
            return link.source.identifier(as: Note.self)
        }
        return try await database.read { db in
            let repository = NoteRepository(db)
            return try sourceIDs.compactMap { try repository.note($0) }
        }
    }
}
