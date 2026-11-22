import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The public API for collections: the folder hierarchy that holds notes and documents.
///
/// Deleting a collection never deletes content: its notes, documents and child collections move
/// up to the deleted collection's parent (or to the root for a top-level collection), and each
/// moved item is saved with a change record and announced with its own `updated` event.
public final class CollectionService: Sendable {
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

    // MARK: - Reading

    public func collection(_ id: NoteCollection.ID) async throws -> NoteCollection? {
        try await database.read { db in try CollectionRepository(db).collection(id) }
    }

    /// Every collection, flat.
    public func all() async throws -> [NoteCollection] {
        try await database.read { db in try CollectionRepository(db).allCollections() }
    }

    /// The nested hierarchy in display order (see `CollectionHierarchy.tree(of:)`).
    public func tree() async throws -> [CollectionNode] {
        CollectionHierarchy.tree(of: try await all())
    }

    /// Direct children of `parentID` (`nil`: top level), in display order.
    public func children(of parentID: NoteCollection.ID?) async throws -> [NoteCollection] {
        try await database.read { db in try CollectionRepository(db).children(of: parentID) }
    }

    // MARK: - Mutating

    /// Creates a collection at the end of its siblings.
    @discardableResult
    public func create(
        name: String,
        parentID: NoteCollection.ID? = nil,
        symbolName: String? = nil,
        context: ActionContext = .user
    ) async throws -> NoteCollection {
        let name = try Self.validName(name)
        let symbol = symbolName?.nonBlank
        let now = timeSource.now()
        let created: NoteCollection = try await database.write { db in
            let repository = CollectionRepository(db)
            if let parentID, try repository.collection(parentID) == nil {
                throw DatabaseError.notFound(EntityReference(kind: .collection, id: parentID))
            }
            let collection = NoteCollection(
                name: name,
                parentID: parentID,
                sortOrder: try repository.nextSortOrder(in: parentID),
                symbolName: symbol,
                createdAt: now,
                updatedAt: now
            )
            try repository.save(collection)
            return collection
        }
        logger.info("Collection created", metadata: ["collection": created.id.uuidString])
        events.publish(context.event(KnowledgeEvents.collectionCreated, entity: created.reference, attributes: Self.attributes(of: created), at: now))
        return created
    }

    @discardableResult
    public func rename(_ id: NoteCollection.ID, to name: String, context: ActionContext = .user) async throws -> NoteCollection {
        let name = try Self.validName(name)
        return try await mutate(id, context: context) { collection, _ in
            collection.name = name
        }
    }

    /// Sets or clears (`nil` or blank) the SF Symbol shown for the collection.
    @discardableResult
    public func setSymbol(_ id: NoteCollection.ID, _ symbolName: String?, context: ActionContext = .user) async throws -> NoteCollection {
        let symbol = symbolName?.nonBlank
        return try await mutate(id, context: context) { collection, _ in
            collection.symbolName = symbol
        }
    }

    /// Moves the collection under `parentID` (or to the top level), after the new siblings.
    /// Throws a `ValidationError` when `parentID` is the collection itself or one of its descendants.
    @discardableResult
    public func move(_ id: NoteCollection.ID, to parentID: NoteCollection.ID?, context: ActionContext = .user) async throws -> NoteCollection {
        try await mutate(id, context: context) { collection, db in
            guard collection.parentID != parentID else { return }
            let repository = CollectionRepository(db)
            if let parentID, try repository.collection(parentID) == nil {
                throw DatabaseError.notFound(EntityReference(kind: .collection, id: parentID))
            }
            if CollectionHierarchy.wouldCreateCycle(moving: id, under: parentID, in: try repository.allCollections()) {
                throw ValidationError(field: "parent", reason: "A collection can't be moved into itself or one of its own collections.")
            }
            collection.parentID = parentID
            collection.sortOrder = try repository.nextSortOrder(in: parentID)
        }
    }

    /// Orders the children of `parentID`: `orderedIDs` first, in the given order, then any other
    /// children in their current order. Every listed collection must be a child of `parentID`.
    /// Returns the children in their new order.
    @discardableResult
    public func reorder(
        _ orderedIDs: [NoteCollection.ID],
        in parentID: NoteCollection.ID?,
        context: ActionContext = .user
    ) async throws -> [NoteCollection] {
        let now = timeSource.now()
        let outcome: ReorderOutcome = try await database.write { db in
            let repository = CollectionRepository(db)
            let siblings = try repository.children(of: parentID)
            let siblingIDs = Set(siblings.map(\.id))
            guard Set(orderedIDs).count == orderedIDs.count, orderedIDs.allSatisfy(siblingIDs.contains) else {
                throw ValidationError(field: "order", reason: "Only collections in the same place can be reordered together.")
            }
            let listed = Set(orderedIDs)
            let byID = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0) })
            let ordered = orderedIDs.compactMap { byID[$0] } + siblings.filter { !listed.contains($0.id) }
            var result: [NoteCollection] = []
            var changed: [NoteCollection] = []
            for (index, var collection) in ordered.enumerated() {
                if collection.sortOrder != index {
                    collection.sortOrder = index
                    collection.updatedAt = now
                    try repository.save(collection)
                    changed.append(collection)
                }
                result.append(collection)
            }
            return ReorderOutcome(ordered: result, changed: changed)
        }
        events.publish(outcome.changed.map {
            context.event(KnowledgeEvents.collectionUpdated, entity: $0.reference, attributes: Self.attributes(of: $0), at: now)
        })
        return outcome.ordered
    }

    /// Deletes the collection; its notes, documents and child collections move to its parent.
    public func delete(_ id: NoteCollection.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let outcome: DeleteOutcome = try await database.write { db in
            let collections = CollectionRepository(db)
            guard let collection = try collections.collection(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .collection, id: id))
            }
            // A parent that is missing locally (not synchronized yet) counts as the root.
            var destination = collection.parentID
            if let parentID = destination, try collections.collection(parentID) == nil {
                destination = nil
            }

            var movedChildren: [NoteCollection] = []
            var nextOrder = try collections.nextSortOrder(in: destination)
            for var child in try collections.children(of: id) {
                child.parentID = destination
                child.sortOrder = nextOrder
                child.updatedAt = now
                nextOrder += 1
                try collections.save(child)
                movedChildren.append(child)
            }

            let notes = NoteRepository(db)
            var movedNotes: [Note] = []
            for var note in try notes.notes(inCollection: id) {
                note.collectionID = destination
                note.updatedAt = now
                try notes.save(note)
                movedNotes.append(note)
            }

            let documents = DocumentRepository(db)
            var movedDocuments: [DocumentItem] = []
            for var document in try documents.documents(inCollection: id) {
                document.collectionID = destination
                document.updatedAt = now
                try documents.save(document)
                movedDocuments.append(document)
            }

            try collections.delete(id)
            return DeleteOutcome(collection: collection, children: movedChildren, notes: movedNotes, documents: movedDocuments)
        }

        logger.notice("Collection deleted", metadata: [
            "collection": id.uuidString,
            "movedNotes": String(outcome.notes.count),
            "movedDocuments": String(outcome.documents.count),
        ])
        var published: [DomainEvent] = []
        var attributes = Self.attributes(of: outcome.collection)
        attributes["movedNoteCount"] = .number(Double(outcome.notes.count))
        attributes["movedDocumentCount"] = .number(Double(outcome.documents.count))
        attributes["movedCollectionCount"] = .number(Double(outcome.children.count))
        published.append(context.event(KnowledgeEvents.collectionDeleted, entity: outcome.collection.reference, attributes: attributes, at: now))
        published += outcome.children.map {
            context.event(KnowledgeEvents.collectionUpdated, entity: $0.reference, attributes: Self.attributes(of: $0), at: now)
        }
        published += outcome.notes.map {
            context.event(KnowledgeEvents.noteUpdated, entity: $0.reference, attributes: NoteService.attributes(of: $0), at: now)
        }
        published += outcome.documents.map {
            context.event(KnowledgeEvents.documentUpdated, entity: $0.reference, attributes: DocumentService.attributes(of: $0), at: now)
        }
        events.publish(published)
    }

    // MARK: - Internals

    private struct ReorderOutcome: Sendable {
        var ordered: [NoteCollection]
        var changed: [NoteCollection]
    }

    private struct DeleteOutcome: Sendable {
        var collection: NoteCollection
        var children: [NoteCollection]
        var notes: [Note]
        var documents: [DocumentItem]
    }

    private struct MutationOutcome: Sendable {
        var collection: NoteCollection
        var changed: Bool
    }

    /// Loads, changes and (when different) saves one collection, then publishes `updated`.
    private func mutate(
        _ id: NoteCollection.ID,
        context: ActionContext,
        _ change: @escaping @Sendable (inout NoteCollection, DatabaseConnection) throws -> Void
    ) async throws -> NoteCollection {
        let now = timeSource.now()
        let outcome: MutationOutcome = try await database.write { db in
            let repository = CollectionRepository(db)
            guard let original = try repository.collection(id) else {
                throw DatabaseError.notFound(EntityReference(kind: .collection, id: id))
            }
            var updated = original
            try change(&updated, db)
            guard updated != original else { return MutationOutcome(collection: original, changed: false) }
            updated.updatedAt = now
            try repository.save(updated)
            return MutationOutcome(collection: updated, changed: true)
        }
        guard outcome.changed else { return outcome.collection }
        events.publish(context.event(KnowledgeEvents.collectionUpdated, entity: outcome.collection.reference, attributes: Self.attributes(of: outcome.collection), at: now))
        return outcome.collection
    }

    private static func validName(_ name: String) throws -> String {
        guard let name = name.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "name", reason: "A collection needs a name.")
        }
        return name
    }

    static func attributes(of collection: NoteCollection) -> [String: JSONValue] {
        var attributes: [String: JSONValue] = [:]
        if let parentID = collection.parentID {
            attributes["parentID"] = .string(parentID.uuidString)
        }
        return attributes
    }
}
