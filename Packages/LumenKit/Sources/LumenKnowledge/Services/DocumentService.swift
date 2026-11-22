import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The public API for imported documents.
///
/// Files are content-addressed: the bytes are stored under `<sha256>.<extension>` and importing
/// bytes that are already in the library returns the existing document without writing anything.
/// A file is removed from storage only when no document references its key any more.
public final class DocumentService: Sendable {
    /// Extracted text of text documents is cut to this many characters.
    public static let maximumExtractedCharacters = 200_000

    private let database: Database
    private let storage: any DocumentStorage
    private let extractors: [any DocumentTextExtractor]
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger

    /// - Parameter extractors: platform text extractors for formats beyond UTF-8 text (PDF);
    ///   the first one that accepts a document's type is used.
    public init(
        database: Database,
        storage: any DocumentStorage,
        extractors: [any DocumentTextExtractor] = [],
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger
    ) {
        self.database = database
        self.storage = storage
        self.extractors = extractors
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
    }

    // MARK: - Importing

    /// Imports a file. Returns the existing document when the same bytes were imported before.
    ///
    /// - Parameters:
    ///   - contentType: uniform type identifier (see `DocumentContentType`); text is extracted for
    ///     plain text, Markdown, JSON and CSV.
    ///   - title: display title; defaults to the file name without its extension.
    @discardableResult
    public func `import`(
        data: Data,
        fileName: String,
        contentType: String,
        title: String? = nil,
        collectionID: NoteCollection.ID? = nil,
        tags: [String] = [],
        context: ActionContext = .user
    ) async throws -> DocumentItem {
        guard let fileName = fileName.nonBlank else {
            throw ValidationError(field: "fileName", reason: "The file needs a name.")
        }
        guard let contentType = contentType.nonBlank else {
            throw ValidationError(field: "contentType", reason: "The file's type is unknown.")
        }
        let digest = SHA256.hexDigest(of: data)
        let key = DocumentContentType.storageKey(sha256: digest, fileName: fileName, contentType: contentType)

        if let existing = try await database.read({ db in try DocumentRepository(db).firstDocument(withSHA256: digest) }) {
            try await restoreFileIfMissing(existing, data: data)
            logger.debug("Document import matched an existing document", metadata: ["document": existing.id.uuidString])
            return existing
        }

        let extractedText = await extractText(from: data, contentType: contentType)
        try await storage.write(data, key: key)
        let now = timeSource.now()
        let document = DocumentItem(
            title: title?.collapsingWhitespace.nonBlank ?? Self.defaultTitle(for: fileName),
            originalFileName: fileName,
            contentType: contentType,
            byteCount: Int64(data.count),
            sha256: digest,
            storageKey: key,
            collectionID: collectionID,
            tags: TagNormalizer.normalize(tags),
            extractedText: extractedText,
            createdAt: now,
            updatedAt: now
        )

        let outcome: ImportOutcome
        do {
            outcome = try await database.write { db in
                let repository = DocumentRepository(db)
                // Re-check inside the transaction: a concurrent import of the same bytes may have won.
                if let existing = try repository.firstDocument(withSHA256: digest) {
                    return ImportOutcome(document: existing, inserted: false)
                }
                if let collectionID, try CollectionRepository(db).collection(collectionID) == nil {
                    throw DatabaseError.notFound(EntityReference(kind: .collection, id: collectionID))
                }
                try repository.save(document)
                return ImportOutcome(document: document, inserted: true)
            }
        } catch {
            await removeFileIfUnreferenced(key)
            throw error
        }

        guard outcome.inserted else {
            if outcome.document.storageKey != key {
                await removeFileIfUnreferenced(key)
            }
            return outcome.document
        }
        logger.info("Document imported", metadata: ["document": document.id.uuidString, "bytes": String(data.count)])
        var attributes = Self.attributes(of: document)
        attributes["contentType"] = .string(document.contentType)
        attributes["byteCount"] = .number(Double(document.byteCount))
        events.publish(context.event(KnowledgeEvents.documentImported, entity: document.reference, attributes: attributes, at: now))
        return document
    }

    // MARK: - Editing

    @discardableResult
    public func rename(_ id: DocumentItem.ID, to title: String, context: ActionContext = .user) async throws -> DocumentItem {
        guard let title = title.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "title", reason: "A document needs a title.")
        }
        return try await mutate(id, context: context) { document, _ in
            document.title = title
        }
    }

    @discardableResult
    public func setTags(_ id: DocumentItem.ID, _ tags: [String], context: ActionContext = .user) async throws -> DocumentItem {
        let normalized = TagNormalizer.normalize(tags)
        return try await mutate(id, context: context) { document, _ in
            document.tags = normalized
        }
    }

    /// Moves the document into `collectionID`, or to the root when `nil`.
    @discardableResult
    public func move(_ id: DocumentItem.ID, to collectionID: NoteCollection.ID?, context: ActionContext = .user) async throws -> DocumentItem {
        try await mutate(id, context: context) { document, db in
            guard document.collectionID != collectionID else { return }
            if let collectionID, try CollectionRepository(db).collection(collectionID) == nil {
                throw DatabaseError.notFound(EntityReference(kind: .collection, id: collectionID))
            }
            document.collectionID = collectionID
        }
    }

    /// Deletes the document and records the deletion. Its file is removed after the commit unless
    /// another document still references it; a failed removal is logged and leaves an orphan file,
    /// it does not undo the deletion.
    public func delete(_ id: DocumentItem.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let outcome: DeleteOutcome = try await database.write { db in
            let repository = DocumentRepository(db)
            guard let document = try repository.document(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .document, id: id))
            }
            try repository.delete(id)
            return DeleteOutcome(document: document, remainingReferences: try repository.referenceCount(storageKey: document.storageKey))
        }
        if outcome.remainingReferences == 0 {
            do {
                try await storage.remove(key: outcome.document.storageKey)
            } catch {
                logger.error("Document file could not be removed", error: error, metadata: ["document": id.uuidString])
            }
        }
        logger.notice("Document deleted", metadata: ["document": id.uuidString])
        events.publish(context.event(KnowledgeEvents.documentDeleted, entity: outcome.document.reference, attributes: Self.attributes(of: outcome.document), at: now))
    }

    // MARK: - Reading

    public func document(_ id: DocumentItem.ID) async throws -> DocumentItem? {
        try await database.read { db in try DocumentRepository(db).document(id) }
    }

    public func documents(query: DocumentQuery = DocumentQuery()) async throws -> [DocumentItem] {
        try await database.read { db in try DocumentRepository(db).documents(matching: query) }
    }

    /// Every document (full reindexing).
    public func allDocuments() async throws -> [DocumentItem] {
        try await database.read { db in try DocumentRepository(db).allDocuments() }
    }

    /// Documents changed after `date`, oldest change first (incremental indexing).
    public func documents(updatedSince date: Date) async throws -> [DocumentItem] {
        try await database.read { db in try DocumentRepository(db).documents(updatedSince: date) }
    }

    /// The document's bytes.
    public func data(for id: DocumentItem.ID) async throws -> Data {
        try await storage.read(key: try await requireDocument(id).storageKey)
    }

    /// A file URL for previewing or sharing the document, when the storage is file-backed.
    public func fileURL(for id: DocumentItem.ID) async throws -> URL? {
        storage.url(for: try await requireDocument(id).storageKey)
    }

    /// The file URL only when the bytes are present on this device (a document synced from
    /// another device may not have its file yet), so a preview never opens a missing file.
    public func availableFileURL(for id: DocumentItem.ID) async throws -> URL? {
        let document = try await requireDocument(id)
        guard await storage.exists(key: document.storageKey) else { return nil }
        return storage.url(for: document.storageKey)
    }

    // MARK: - Internals

    private struct ImportOutcome: Sendable {
        var document: DocumentItem
        var inserted: Bool
    }

    private struct DeleteOutcome: Sendable {
        var document: DocumentItem
        var remainingReferences: Int
    }

    private struct MutationOutcome: Sendable {
        var document: DocumentItem
        var changed: Bool
    }

    private func requireDocument(_ id: DocumentItem.ID) async throws -> DocumentItem {
        guard let document = try await document(id) else {
            throw DatabaseError.notFound(EntityReference(kind: .document, id: id))
        }
        return document
    }

    private func mutate(
        _ id: DocumentItem.ID,
        context: ActionContext,
        _ change: @escaping @Sendable (inout DocumentItem, DatabaseConnection) throws -> Void
    ) async throws -> DocumentItem {
        let now = timeSource.now()
        let outcome: MutationOutcome = try await database.write { db in
            let repository = DocumentRepository(db)
            guard let original = try repository.document(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .document, id: id))
            }
            var updated = original
            try change(&updated, db)
            guard updated != original else { return MutationOutcome(document: original, changed: false) }
            updated.updatedAt = now
            try repository.save(updated)
            return MutationOutcome(document: updated, changed: true)
        }
        guard outcome.changed else { return outcome.document }
        events.publish(context.event(KnowledgeEvents.documentUpdated, entity: outcome.document.reference, attributes: Self.attributes(of: outcome.document), at: now))
        return outcome.document
    }

    /// Text for the search index and the assistant: UTF-8 formats are decoded directly, other
    /// formats go to the first platform extractor that accepts them. A failed extraction is
    /// logged and the document is imported without text; failing the import would lose the file
    /// without recovering the text.
    private func extractText(from data: Data, contentType: String) async -> String? {
        let limit = Self.maximumExtractedCharacters
        if let text = DocumentContentType.extractText(from: data, contentType: contentType, limit: limit) {
            return text
        }
        guard let extractor = extractors.first(where: { $0.canExtract(contentType: contentType) }) else { return nil }
        do {
            return try await extractor.extractText(from: data, contentType: contentType, limit: limit)
        } catch {
            logger.notice("Document text could not be extracted", metadata: [
                "contentType": contentType, "error": String(describing: type(of: error)),
            ])
            return nil
        }
    }

    /// Re-imported bytes repair a document whose file went missing (e.g. restored from a backup
    /// without its files); when the file is present nothing is written.
    private func restoreFileIfMissing(_ document: DocumentItem, data: Data) async throws {
        guard await !storage.exists(key: document.storageKey) else { return }
        try await storage.write(data, key: document.storageKey)
        logger.notice("Restored missing document file", metadata: ["document": document.id.uuidString])
    }

    /// Best-effort cleanup of a file written for an import that did not create a document. A
    /// failure is logged; it never masks the import's own outcome.
    private func removeFileIfUnreferenced(_ key: String) async {
        do {
            let references = try await database.read { db in try DocumentRepository(db).referenceCount(storageKey: key) }
            guard references == 0 else { return }
            try await storage.remove(key: key)
        } catch {
            logger.error("Unused document file could not be removed", error: error)
        }
    }

    static func defaultTitle(for fileName: String) -> String {
        let base: String
        if DocumentContentType.fileExtension(of: fileName) != nil, let dot = fileName.lastIndex(of: ".") {
            base = String(fileName[fileName.startIndex..<dot])
        } else {
            base = fileName
        }
        return base.collapsingWhitespace.nonBlank ?? fileName
    }

    static func attributes(of document: DocumentItem) -> [String: JSONValue] {
        var attributes: [String: JSONValue] = ["tagCount": .number(Double(document.tags.count))]
        if let collectionID = document.collectionID {
            attributes["collectionID"] = .string(collectionID.uuidString)
        }
        return attributes
    }
}
