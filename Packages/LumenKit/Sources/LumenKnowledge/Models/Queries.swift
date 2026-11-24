import Foundation
import LumenFoundation

/// Ordering of note and document lists.
public enum KnowledgeSort: String, Sendable, Hashable, Codable, CaseIterable {
    /// Most recently updated first.
    case updated
    /// Most recently created first.
    case created
    /// Alphabetical by folded title.
    case title
}

/// Filters for `NoteService.notes(query:)`.
public struct NoteQuery: Sendable, Hashable {
    /// Only notes directly in this collection; `nil` means every collection and the root.
    public var collectionID: NoteCollection.ID?
    /// Only notes carrying this tag (normalized before matching).
    public var tag: String?
    public var includeArchived: Bool
    public var pinnedOnly: Bool
    public var sort: KnowledgeSort
    /// Maximum number of notes; `nil` for no limit.
    public var limit: Int?

    public init(
        collectionID: NoteCollection.ID? = nil,
        tag: String? = nil,
        includeArchived: Bool = false,
        pinnedOnly: Bool = false,
        sort: KnowledgeSort = .updated,
        limit: Int? = nil
    ) {
        self.collectionID = collectionID
        self.tag = tag
        self.includeArchived = includeArchived
        self.pinnedOnly = pinnedOnly
        self.sort = sort
        self.limit = limit
    }
}

/// Filters for `DocumentService.documents(query:)`.
public struct DocumentQuery: Sendable, Hashable {
    public var collectionID: NoteCollection.ID?
    public var tag: String?
    /// Only documents of this exact content type.
    public var contentType: String?
    public var sort: KnowledgeSort
    public var limit: Int?

    public init(
        collectionID: NoteCollection.ID? = nil,
        tag: String? = nil,
        contentType: String? = nil,
        sort: KnowledgeSort = .updated,
        limit: Int? = nil
    ) {
        self.collectionID = collectionID
        self.tag = tag
        self.contentType = contentType
        self.sort = sort
        self.limit = limit
    }
}

/// How often a tag is used, as listed by `TagService.allTags()`.
public struct TagUsage: Sendable, Hashable, Identifiable {
    public var tag: String
    public var noteCount: Int
    public var documentCount: Int

    public init(tag: String, noteCount: Int, documentCount: Int) {
        self.tag = tag
        self.noteCount = noteCount
        self.documentCount = documentCount
    }

    public var id: String { tag }
    public var totalCount: Int { noteCount + documentCount }
}

/// What a tag rename or merge changed.
public struct TagChangeSummary: Sendable, Hashable {
    public var notesUpdated: Int
    public var documentsUpdated: Int

    public init(notesUpdated: Int = 0, documentsUpdated: Int = 0) {
        self.notesUpdated = notesUpdated
        self.documentsUpdated = documentsUpdated
    }
}
