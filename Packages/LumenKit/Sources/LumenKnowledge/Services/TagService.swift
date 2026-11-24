import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Tags across notes and documents: usage counts, renaming and merging.
///
/// Renames and merges rewrite matching `#hashtags` in note bodies too, so a renamed tag does not
/// reappear from the old hashtag on the next edit. They do not create note versions. Every changed
/// note and document is saved with a change record and announced with an `updated` event.
public final class TagService: Sendable {
    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger

    public init(database: Database, events: EventBus, timeSource: any TimeSource, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
    }

    /// Every tag in use (archived notes included), most used first, then alphabetically.
    public func allTags() async throws -> [TagUsage] {
        try await database.read { db in
            var usage: [String: TagUsage] = [:]
            for row in try db.query(
                "SELECT json_each.value AS tag, count(DISTINCT knowledge_notes.id) AS uses FROM knowledge_notes, json_each(knowledge_notes.tags) GROUP BY json_each.value"
            ) {
                let tag: String = try row.get("tag")
                usage[tag, default: TagUsage(tag: tag, noteCount: 0, documentCount: 0)].noteCount = try row.get("uses")
            }
            for row in try db.query(
                "SELECT json_each.value AS tag, count(DISTINCT knowledge_documents.id) AS uses FROM knowledge_documents, json_each(knowledge_documents.tags) GROUP BY json_each.value"
            ) {
                let tag: String = try row.get("tag")
                usage[tag, default: TagUsage(tag: tag, noteCount: 0, documentCount: 0)].documentCount = try row.get("uses")
            }
            return usage.values.sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return lhs.tag < rhs.tag
            }
        }
    }

    /// Renames `oldTag` to `newTag` everywhere. Renaming onto an existing tag merges the two.
    @discardableResult
    public func renameTag(_ oldTag: String, to newTag: String, context: ActionContext = .user) async throws -> TagChangeSummary {
        try await mergeTags([oldTag], into: newTag, context: context)
    }

    /// Replaces every tag in `sourceTags` by `targetTag` on all notes and documents.
    ///
    /// Throws a `ValidationError` when `targetTag` is empty, or when a note uses a source tag as a
    /// `#hashtag` and `targetTag` cannot be written as one (see `TagNormalizer.isHashtagCompatible`).
    @discardableResult
    public func mergeTags(_ sourceTags: [String], into targetTag: String, context: ActionContext = .user) async throws -> TagChangeSummary {
        let target = try TagNormalizer.validated(targetTag)
        let sources = Set(TagNormalizer.normalize(sourceTags)).subtracting([target])
        guard !sources.isEmpty else { return TagChangeSummary() }
        let now = timeSource.now()

        let outcome: MergeOutcome = try await database.write { db in
            let notes = NoteRepository(db)
            var changedNotes: [Note] = []
            for var note in try notes.notes(taggedWithAny: Array(sources).sorted()) {
                var body = note.body
                if NoteTagging.containsHashtag(for: sources, in: body) {
                    guard TagNormalizer.isHashtagCompatible(target) else {
                        throw ValidationError(field: "tag", reason: "The new name can't be written as a #hashtag, which some notes use for this tag.")
                    }
                    body = NoteTagging.rewritingHashtags(in: body, replacing: sources, with: target)
                }
                let explicit = NoteTagging.explicitTags(note.tags, body: note.body).map { sources.contains($0) ? target : $0 }
                note.body = body
                note.tags = NoteTagging.tags(explicit: explicit, body: body)
                note.updatedAt = now
                try notes.save(note)
                changedNotes.append(note)
            }

            let documents = DocumentRepository(db)
            var changedDocuments: [DocumentItem] = []
            for var document in try documents.documents(taggedWithAny: Array(sources).sorted()) {
                document.tags = TagNormalizer.normalize(document.tags.map { sources.contains($0) ? target : $0 })
                document.updatedAt = now
                try documents.save(document)
                changedDocuments.append(document)
            }
            return MergeOutcome(notes: changedNotes, documents: changedDocuments)
        }

        logger.info("Tags merged", metadata: [
            "sourceCount": String(sources.count),
            "notes": String(outcome.notes.count),
            "documents": String(outcome.documents.count),
        ])
        events.publish(
            outcome.notes.map {
                context.event(KnowledgeEvents.noteUpdated, entity: $0.reference, attributes: NoteService.attributes(of: $0), at: now)
            } + outcome.documents.map {
                context.event(KnowledgeEvents.documentUpdated, entity: $0.reference, attributes: DocumentService.attributes(of: $0), at: now)
            }
        )
        return TagChangeSummary(notesUpdated: outcome.notes.count, documentsUpdated: outcome.documents.count)
    }

    private struct MergeOutcome: Sendable {
        var notes: [Note]
        var documents: [DocumentItem]
    }
}
