import Foundation
import LumenFoundation

/// A Markdown note.
///
/// `tags` holds normalized tags: the ones the user set explicitly plus every `#hashtag` found in
/// the body (see `NoteTagging`).
public struct Note: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<Note>

    public static let defaultExcerptLength = 160

    public let id: ID
    public var title: String
    /// Markdown source.
    public var body: String
    public var collectionID: NoteCollection.ID?
    public var tags: [String]
    public var isPinned: Bool
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        title: String,
        body: String = "",
        collectionID: NoteCollection.ID? = nil,
        tags: [String] = [],
        isPinned: Bool = false,
        isArchived: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.collectionID = collectionID
        self.tags = tags
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reference: EntityReference { EntityReference(kind: .note, id: id) }

    /// The body as plain text (Markdown syntax removed), whitespace collapsed and truncated.
    /// Parses the body on every access.
    public var excerpt: String { excerpt(maximumLength: Self.defaultExcerptLength) }

    public func excerpt(maximumLength: Int) -> String {
        MarkdownStructure(parsing: body).plainText.collapsingWhitespace.truncated(to: maximumLength)
    }

    /// Words in the body's plain text. Parses the body on every access.
    public var wordCount: Int { MarkdownStructure(parsing: body).wordCount }
}

extension Note {
    enum CodingKeys: String, CodingKey {
        case id, title, body, collectionID, tags, isPinned, isArchived, createdAt, updatedAt
    }

    /// Decodes snapshots written by any release: fields added after the first release fall back
    /// to defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "",
            collectionID: try container.decodeIfPresent(NoteCollection.ID.self, forKey: .collectionID),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }
}
