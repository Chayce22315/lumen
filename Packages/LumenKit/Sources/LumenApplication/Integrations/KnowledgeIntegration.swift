import Foundation
import LumenFoundation
import LumenPersistence
import LumenKnowledge
import LumenPlugins
import LumenSearch
import LumenSync

/// Knowledge's adapters for search and sync.
enum KnowledgeIntegration {
    static func syncHandlers() -> [any SyncEntityHandler] {
        [
            CodableSyncHandler<Note>(
                kind: .note,
                fetch: { id, db in try NoteRepository(db).note(Note.ID(id)) },
                upsert: { note, db in try NoteRepository(db).upsertRow(note) },
                delete: { id, db in try NoteRepository(db).deleteRow(Note.ID(id)) }
            ),
            CodableSyncHandler<NoteCollection>(
                kind: .collection,
                fetch: { id, db in try CollectionRepository(db).collection(NoteCollection.ID(id)) },
                upsert: { collection, db in try CollectionRepository(db).upsertRow(collection) },
                delete: { id, db in try CollectionRepository(db).deleteRow(NoteCollection.ID(id)) }
            ),
            // Document metadata synchronizes; file contents are not part of the change log and
            // need a transport that carries blobs (see ROADMAP: document sync).
            CodableSyncHandler<DocumentItem>(
                kind: .document,
                fetch: { id, db in try DocumentRepository(db).document(DocumentItem.ID(id)) },
                upsert: { document, db in try DocumentRepository(db).upsertRow(document) },
                delete: { id, db in try DocumentRepository(db).deleteRow(DocumentItem.ID(id)) }
            ),
        ]
    }
}

struct NoteSearchSource: SearchableSource {
    let notes: NoteService
    let collections: CollectionService

    var kind: EntityKind { .note }

    func document(for id: UUID) async throws -> SearchDocument? {
        guard let note = try await notes.note(Note.ID(id)) else { return nil }
        let collectionName = try await note.collectionID.asyncMap { try await collections.collection($0)?.name } ?? nil
        return Self.document(for: note, collectionName: collectionName)
    }

    func allDocuments() async throws -> [SearchDocument] {
        let names = Dictionary(try await collections.all().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return try await notes.allNotes().map { Self.document(for: $0, collectionName: $0.collectionID.flatMap { names[$0] }) }
    }

    static func document(for note: Note, collectionName: String?) -> SearchDocument {
        let plain = MarkdownStructure(parsing: note.body).plainText
        var subtitle = ["Note"]
        if let collectionName { subtitle.append(collectionName) }
        if note.isArchived { subtitle.append("Archived") }
        return SearchDocument(
            reference: note.reference,
            title: note.title.nonBlank ?? "Untitled note",
            subtitle: subtitle.joined(separator: " · "),
            body: plain,
            tags: note.tags,
            updatedAt: note.updatedAt,
            boost: note.isArchived ? 0.6 : (note.isPinned ? 1.3 : 1.0)
        )
    }
}

struct DocumentSearchSource: SearchableSource {
    let documents: DocumentService

    var kind: EntityKind { .document }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await documents.document(DocumentItem.ID(id)).map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await documents.allDocuments().map(Self.document(for:))
    }

    static func document(for item: DocumentItem) -> SearchDocument {
        SearchDocument(
            reference: item.reference,
            title: item.title,
            subtitle: "Document · \(item.originalFileName)",
            body: item.extractedText ?? "",
            tags: item.tags,
            updatedAt: item.updatedAt
        )
    }
}

struct CollectionSearchSource: SearchableSource {
    let collections: CollectionService

    var kind: EntityKind { .collection }

    func document(for id: UUID) async throws -> SearchDocument? {
        try await collections.collection(NoteCollection.ID(id)).map(Self.document(for:))
    }

    func allDocuments() async throws -> [SearchDocument] {
        try await collections.all().map(Self.document(for:))
    }

    static func document(for collection: NoteCollection) -> SearchDocument {
        SearchDocument(reference: collection.reference, title: collection.name, subtitle: "Collection", updatedAt: collection.updatedAt, boost: 0.9)
    }
}

/// Notes, documents and collections: search sources and commands.
struct KnowledgeFeature: LumenPlugin {
    let notes: NoteService
    let collections: CollectionService
    let documents: DocumentService
    let timeSource: any TimeSource
    let calendar: Calendar

    let manifest = PluginManifest(
        id: "app.lumen.knowledge",
        name: "Notes & Documents",
        summary: "Notes, documents, collections, links and history.",
        author: "Lumen",
        version: builtInVersion,
        capabilities: [.contributeCommands, .contributeSearchResults, .readNotes, .writeNotes]
    )

    func activate(_ context: PluginContext) async throws {
        try context.contribute(NoteSearchSource(notes: notes, collections: collections), to: LumenExtensionPoints.searchSources)
        try context.contribute(DocumentSearchSource(documents: documents), to: LumenExtensionPoints.searchSources)
        try context.contribute(CollectionSearchSource(collections: collections), to: LumenExtensionPoints.searchSources)

        let notes = self.notes
        let timeSource = self.timeSource
        let calendar = self.calendar
        try context.contribute(
            LumenCommand(
                PaletteCommand(id: "notes.daily", title: "Today's journal", subtitle: "Opens or creates the note for today", symbolName: "book", keywords: ["daily", "journal", "diary"], category: "Notes"),
                action: .perform {
                    let title = DailyNote.title(for: timeSource.now(), calendar: calendar)
                    if let existing = try await notes.resolveTitle(title) {
                        return CommandResult(destination: .entity(existing.reference))
                    }
                    let created = try await notes.create(title: title, body: "", collectionID: nil, tags: ["journal"], context: .user)
                    return CommandResult(message: "Created \(title).", destination: .entity(created.reference))
                }
            ),
            to: LumenExtensionPoints.commands
        )
    }
}

/// Naming of daily journal notes.
enum DailyNote {
    static func title(for date: Date, calendar: Calendar) -> String {
        "Journal \(CalendarDate(date, calendar: calendar))"
    }
}
