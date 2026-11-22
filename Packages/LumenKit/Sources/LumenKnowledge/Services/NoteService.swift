import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The public API for notes: creating and editing, tagging, organizing, history and links.
///
/// Every mutation runs in one transaction that writes the note row, its change record, its link
/// index and (per `VersionPolicy`) a version snapshot; the domain event is published after the
/// transaction commits. Mutations that change nothing write nothing and publish nothing.
///
/// Queries, links and version history live in the `NoteService+Queries` and
/// `NoteService+Versions` extensions.
public final class NoteService: Sendable {
    let database: Database
    let events: EventBus
    let timeSource: any TimeSource
    let logger: Logger
    public let versionPolicy: VersionPolicy

    public init(
        database: Database,
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger,
        versionPolicy: VersionPolicy = VersionPolicy()
    ) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
        self.versionPolicy = versionPolicy
    }

    // MARK: - Creating

    /// Creates a note. Hashtags in `body` are added to `tags`; the first version is saved.
    @discardableResult
    public func create(
        title: String,
        body: String = "",
        collectionID: NoteCollection.ID? = nil,
        tags: [String] = [],
        context: ActionContext = .user
    ) async throws -> Note {
        let now = timeSource.now()
        let note = Note(
            title: Self.cleanTitle(title),
            body: body,
            collectionID: collectionID,
            tags: NoteTagging.tags(explicit: tags, body: body),
            createdAt: now,
            updatedAt: now
        )
        let policy = versionPolicy
        try await database.write { db in
            if let collectionID {
                try Self.requireCollection(collectionID, in: db)
            }
            try NoteRepository(db).save(note)
            try Self.snapshotIfNeeded(note, policy: policy, now: now, in: db)
        }
        logger.info("Note created", metadata: ["note": note.id.uuidString])
        events.publish(context.event(KnowledgeEvents.noteCreated, entity: note.reference, attributes: Self.attributes(of: note), at: now))
        return note
    }

    // MARK: - Editing

    /// Changes the title and/or body. Tags are re-derived from the body's hashtags (explicit tags
    /// are kept), links are re-extracted and a version is saved when the policy says so.
    @discardableResult
    public func update(_ id: Note.ID, title: String? = nil, body: String? = nil, context: ActionContext = .user) async throws -> Note {
        let cleanedTitle = title.map(Self.cleanTitle)
        return try await mutate(id, event: KnowledgeEvents.noteUpdated, context: context) { note in
            if let cleanedTitle {
                note.title = cleanedTitle
            }
            if let body {
                note.tags = NoteTagging.retag(note.tags, previousBody: note.body, newBody: body)
                note.body = body
            }
        }
    }

    /// Replaces the explicit tags. Hashtags written in the body remain tags.
    @discardableResult
    public func setTags(_ id: Note.ID, _ tags: [String], context: ActionContext = .user) async throws -> Note {
        try await mutate(id, event: KnowledgeEvents.noteUpdated, context: context) { note in
            note.tags = NoteTagging.tags(explicit: tags, body: note.body)
        }
    }

    /// Moves the note into `collectionID`, or to the root when `nil`.
    @discardableResult
    public func move(_ id: Note.ID, to collectionID: NoteCollection.ID?, context: ActionContext = .user) async throws -> Note {
        try await mutate(id, event: KnowledgeEvents.noteUpdated, context: context) { note in
            note.collectionID = collectionID
        }
    }

    @discardableResult
    public func pin(_ id: Note.ID, context: ActionContext = .user) async throws -> Note {
        try await setPinned(id, true, context: context)
    }

    @discardableResult
    public func unpin(_ id: Note.ID, context: ActionContext = .user) async throws -> Note {
        try await setPinned(id, false, context: context)
    }

    @discardableResult
    public func setPinned(_ id: Note.ID, _ isPinned: Bool, context: ActionContext = .user) async throws -> Note {
        try await mutate(id, event: KnowledgeEvents.noteUpdated, context: context) { note in
            note.isPinned = isPinned
        }
    }

    /// Archives the note (hidden from default queries). Publishes `knowledge.note.archived`.
    @discardableResult
    public func archive(_ id: Note.ID, context: ActionContext = .user) async throws -> Note {
        try await mutate(id, event: KnowledgeEvents.noteArchived, context: context) { note in
            note.isArchived = true
        }
    }

    /// Brings an archived note back. Publishes `knowledge.note.restored`.
    @discardableResult
    public func unarchive(_ id: Note.ID, context: ActionContext = .user) async throws -> Note {
        try await mutate(id, event: KnowledgeEvents.noteRestored, context: context) { note in
            note.isArchived = false
        }
    }

    /// Deletes the note with its outgoing links and version history and records the deletion.
    /// `[[Title]]` links in other notes that pointed at it become unresolved again.
    public func delete(_ id: Note.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let deleted: Note = try await database.write { db in
            let repository = NoteRepository(db)
            guard let note = try repository.note(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .note, id: id))
            }
            try repository.delete(id)
            return note
        }
        logger.notice("Note deleted", metadata: ["note": id.uuidString])
        events.publish(context.event(KnowledgeEvents.noteDeleted, entity: deleted.reference, attributes: Self.attributes(of: deleted), at: now))
    }

    // MARK: - Shared

    /// Loads the note, applies `change` and, when anything changed, saves it (bumping `updatedAt`),
    /// snapshots a version if title or body changed, and publishes `event` after commit.
    func mutate(
        _ id: Note.ID,
        event: EventName,
        context: ActionContext,
        _ change: @escaping @Sendable (inout Note) throws -> Void
    ) async throws -> Note {
        let now = timeSource.now()
        let policy = versionPolicy
        let outcome: MutationOutcome = try await database.write { db in
            let repository = NoteRepository(db)
            guard let original = try repository.note(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .note, id: id))
            }
            var updated = original
            try change(&updated)
            guard updated != original else { return MutationOutcome(note: original, changed: false) }
            if updated.collectionID != original.collectionID, let collectionID = updated.collectionID {
                try Self.requireCollection(collectionID, in: db)
            }
            updated.updatedAt = now
            try repository.save(updated)
            if updated.title != original.title || updated.body != original.body {
                try Self.snapshotIfNeeded(updated, policy: policy, now: now, in: db)
            }
            return MutationOutcome(note: updated, changed: true)
        }
        guard outcome.changed else { return outcome.note }
        logger.debug("Note updated", metadata: ["note": id.uuidString, "event": event.rawValue])
        events.publish(context.event(event, entity: outcome.note.reference, attributes: Self.attributes(of: outcome.note), at: now))
        return outcome.note
    }

    struct MutationOutcome: Sendable {
        var note: Note
        var changed: Bool
    }

    /// Saves a version of `note` when `policy` asks for one, then prunes old versions.
    @discardableResult
    static func snapshotIfNeeded(_ note: Note, policy: VersionPolicy, now: Date, in db: DatabaseConnection) throws -> Bool {
        let versions = NoteVersionRepository(db)
        let latest = try versions.latestVersion(of: note.id)
        guard policy.shouldCreateVersion(latest: latest, title: note.title, body: note.body, now: now) else { return false }
        try versions.insert(NoteVersion(noteID: note.id, title: note.title, body: note.body, savedAt: now))
        try prune(note.id, policy: policy, in: db)
        return true
    }

    static func prune(_ noteID: Note.ID, policy: VersionPolicy, in db: DatabaseConnection) throws {
        let versions = NoteVersionRepository(db)
        let stale = policy.versionsToPrune(try versions.versions(of: noteID))
        if !stale.isEmpty {
            try versions.delete(stale)
        }
    }

    static func requireCollection(_ id: NoteCollection.ID, in db: DatabaseConnection) throws {
        guard try CollectionRepository(db).collection(id) != nil else {
            throw DatabaseError.notFound(EntityReference(kind: .collection, id: id))
        }
    }

    /// Titles are single-line: surrounding whitespace is trimmed and inner whitespace collapsed.
    static func cleanTitle(_ title: String) -> String {
        title.collapsingWhitespace
    }

    static func attributes(of note: Note) -> [String: JSONValue] {
        var attributes: [String: JSONValue] = ["tagCount": .number(Double(note.tags.count))]
        if let collectionID = note.collectionID {
            attributes["collectionID"] = .string(collectionID.uuidString)
        }
        return attributes
    }
}
