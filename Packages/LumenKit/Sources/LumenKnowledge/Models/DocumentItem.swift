import Foundation
import LumenFoundation

/// An imported file (PDF, image, text, Markdown, …). The bytes live in a `DocumentStorage`
/// under `storageKey`; the database holds the metadata and, for text formats, the extracted text.
public struct DocumentItem: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<DocumentItem>

    public let id: ID
    public var title: String
    public var originalFileName: String
    /// Uniform type identifier, e.g. `public.plain-text`, `com.adobe.pdf` (see `DocumentContentType`).
    public var contentType: String
    public var byteCount: Int64
    /// Lowercase hexadecimal SHA-256 of the file's bytes.
    public var sha256: String
    /// File name inside the storage directory: `<sha256>.<extension>`.
    public var storageKey: String
    public var collectionID: NoteCollection.ID?
    public var tags: [String]
    /// UTF-8 text of plain-text, Markdown, JSON and CSV files, capped; `nil` for other formats.
    public var extractedText: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        title: String,
        originalFileName: String,
        contentType: String,
        byteCount: Int64,
        sha256: String,
        storageKey: String,
        collectionID: NoteCollection.ID? = nil,
        tags: [String] = [],
        extractedText: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.originalFileName = originalFileName
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.storageKey = storageKey
        self.collectionID = collectionID
        self.tags = tags
        self.extractedText = extractedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reference: EntityReference { EntityReference(kind: .document, id: id) }
}

extension DocumentItem {
    enum CodingKeys: String, CodingKey {
        case id, title, originalFileName, contentType, byteCount, sha256, storageKey
        case collectionID, tags, extractedText, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? originalFileName,
            originalFileName: originalFileName,
            contentType: try container.decodeIfPresent(String.self, forKey: .contentType) ?? DocumentContentType.data,
            byteCount: try container.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0,
            sha256: try container.decode(String.self, forKey: .sha256),
            storageKey: try container.decode(String.self, forKey: .storageKey),
            collectionID: try container.decodeIfPresent(NoteCollection.ID.self, forKey: .collectionID),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            extractedText: try container.decodeIfPresent(String.self, forKey: .extractedText),
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }
}
