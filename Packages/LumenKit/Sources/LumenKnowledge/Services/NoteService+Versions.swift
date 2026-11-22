import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

extension NoteService {
    /// Saved versions of a note, newest first.
    public func versions(of noteID: Note.ID) async throws -> [NoteVersion] {
        try await database.read { db in try NoteVersionRepository(db).versions(of: noteID) }
    }

    public func version(_ id: NoteVersion.ID) async throws -> NoteVersion? {
        try await database.read { db in try NoteVersionRepository(db).version(id) }
    }

    /// Puts the title and body of `versionID` back into its note.
    ///
    /// The note's current state is saved as a version first (unless the latest version already
    /// holds it), so restoring can itself be undone. Publishes `knowledge.note.updated` with a
    /// `restoredVersionID` attribute. Restoring a version identical to the current state changes
    /// nothing.
    @discardableResult
    public func restore(_ versionID: NoteVersion.ID, context: ActionContext = .user) async throws -> Note {
        let now = timeSource.now()
        let policy = versionPolicy
        let outcome: MutationOutcome = try await database.write { db in
            let versions = NoteVersionRepository(db)
            let notes = NoteRepository(db)
            guard let version = try versions.version(versionID) else {
                throw KnowledgeError.versionNotFound(versionID)
            }
            guard let current = try notes.note(version.noteID) else {
                throw DatabaseError.notFound(EntityReference(kind: .note, id: version.noteID))
            }
            if version.matches(title: current.title, body: current.body) {
                return MutationOutcome(note: current, changed: false)
            }
            if try versions.latestVersion(of: current.id)?.matches(title: current.title, body: current.body) != true {
                try versions.insert(NoteVersion(noteID: current.id, title: current.title, body: current.body, savedAt: now))
            }
            var restored = current
            restored.tags = NoteTagging.retag(current.tags, previousBody: current.body, newBody: version.body)
            restored.title = version.title
            restored.body = version.body
            restored.updatedAt = now
            try notes.save(restored)
            try Self.prune(current.id, policy: policy, in: db)
            return MutationOutcome(note: restored, changed: true)
        }
        guard outcome.changed else { return outcome.note }
        logger.info("Note version restored", metadata: ["note": outcome.note.id.uuidString, "version": versionID.uuidString])
        var attributes = Self.attributes(of: outcome.note)
        attributes["restoredVersionID"] = .string(versionID.uuidString)
        events.publish(context.event(KnowledgeEvents.noteUpdated, entity: outcome.note.reference, attributes: attributes, at: now))
        return outcome.note
    }

    /// Line diff of the body from version `fromID` to version `toID`, or to the note's current
    /// state when `toID` is `nil`.
    public func diff(from fromID: NoteVersion.ID, to toID: NoteVersion.ID? = nil) async throws -> NoteVersionDiff {
        let endpoints: DiffEndpoints = try await database.read { db in
            let versions = NoteVersionRepository(db)
            guard let from = try versions.version(fromID) else { throw KnowledgeError.versionNotFound(fromID) }
            if let toID {
                guard let to = try versions.version(toID) else { throw KnowledgeError.versionNotFound(toID) }
                guard to.noteID == from.noteID else {
                    throw ValidationError(field: "version", reason: "Both versions must belong to the same note.")
                }
                return DiffEndpoints(from: from, toTitle: to.title, toBody: to.body)
            }
            guard let note = try NoteRepository(db).note(from.noteID) else {
                throw DatabaseError.notFound(EntityReference(kind: .note, id: from.noteID))
            }
            return DiffEndpoints(from: from, toTitle: note.title, toBody: note.body)
        }
        // The diff is computed outside the database actor so it never blocks other work.
        return NoteVersionDiff(
            noteID: endpoints.from.noteID,
            fromVersionID: fromID,
            toVersionID: toID,
            oldTitle: endpoints.from.title,
            newTitle: endpoints.toTitle,
            body: LineDiff(old: endpoints.from.body, new: endpoints.toBody)
        )
    }

    struct DiffEndpoints: Sendable {
        var from: NoteVersion
        var toTitle: String
        var toBody: String
    }
}
