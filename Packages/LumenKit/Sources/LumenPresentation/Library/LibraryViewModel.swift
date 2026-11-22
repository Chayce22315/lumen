import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenApplication

/// The Library: notes, collections, tags and documents.
@MainActor
@Observable
public final class LibraryViewModel {
    public enum Filter: Sendable, Hashable {
        case all
        case pinned
        case archived
        case collection(NoteCollection.ID)
        case tag(String)
    }

    public var filter: Filter = .all {
        didSet { Task { await load() } }
    }
    public var sort: KnowledgeSort = .updated {
        didSet { Task { await load() } }
    }
    public private(set) var notes: LoadState<[Note]> = .idle
    public private(set) var collections: [CollectionNode] = []
    public private(set) var tags: [TagUsage] = []
    public private(set) var documents: [DocumentItem] = []

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["knowledge", "sync"]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if notes.value == nil { notes = .loading }
        let knowledge = services.knowledge
        do {
            var query = NoteQuery(sort: sort)
            switch filter {
            case .all: break
            case .pinned: query.pinnedOnly = true
            case .archived: query.includeArchived = true
            case .collection(let id): query.collectionID = id
            case .tag(let tag): query.tag = tag
            }
            var listed = try await knowledge.notes.notes(query: query)
            if filter == .archived { listed = listed.filter(\.isArchived) }
            notes = .loaded(listed)
            collections = try await knowledge.collections.tree()
            tags = try await knowledge.tags.allTags()
            documents = try await knowledge.documents.allDocuments()
        } catch {
            notes = .failed(ErrorPresentation.from(error))
        }
    }

    /// Creates an empty note and returns it for the editor.
    public func createNote() async -> Note? {
        var collectionID: NoteCollection.ID?
        if case .collection(let id) = filter { collectionID = id }
        do {
            return try await services.knowledge.notes.create(title: "", body: "", collectionID: collectionID)
        } catch {
            services.errors.report(error, context: "Creating a note")
            return nil
        }
    }

    public func createCollection(named name: String, parent: NoteCollection.ID? = nil) async {
        do {
            _ = try await services.knowledge.collections.create(name: name, parentID: parent)
            await load()
        } catch {
            services.errors.report(error, context: "Creating a collection")
        }
    }

    public func importDocument(data: Data, fileName: String, contentType: String) async -> DocumentItem? {
        var collectionID: NoteCollection.ID?
        if case .collection(let id) = filter { collectionID = id }
        do {
            let item = try await services.knowledge.documents.import(data: data, fileName: fileName, contentType: contentType, title: nil, collectionID: collectionID, tags: [])
            await load()
            return item
        } catch {
            services.errors.report(error, context: "Importing a document")
            return nil
        }
    }

    public func togglePin(_ note: Note) async {
        await perform("Pinning a note") { _ = try await $0.setPinned(note.id, !note.isPinned) }
    }

    public func setArchived(_ archived: Bool, _ note: Note) async {
        await perform("Archiving a note") { notes in
            if archived { _ = try await notes.archive(note.id) } else { _ = try await notes.unarchive(note.id) }
        }
    }

    public func delete(_ note: Note) async {
        await perform("Deleting a note") { try await $0.delete(note.id) }
    }

    private func perform(_ context: String, _ work: (NoteService) async throws -> Void) async {
        do {
            try await work(services.knowledge.notes)
            await load()
        } catch {
            services.errors.report(error, context: context)
        }
    }
}
