import Foundation
import LumenFoundation

/// What a module hands to the index for one entity.
public struct SearchDocument: Sendable, Hashable {
    public var reference: EntityReference
    public var title: String
    /// Secondary line shown under the title (project name, due date, collection).
    public var subtitle: String
    /// Plain-text body; truncated to `SearchDocument.maximumBodyLength` when indexed.
    public var body: String
    public var tags: [String]
    public var updatedAt: Date
    /// Relevance multiplier set by the source, e.g. `0.6` for archived notes, `1.2` for open tasks.
    public var boost: Double

    public static let maximumBodyLength = 20_000

    public init(reference: EntityReference, title: String, subtitle: String = "", body: String = "", tags: [String] = [], updatedAt: Date, boost: Double = 1) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.tags = tags
        self.updatedAt = updatedAt
        self.boost = boost.isFinite ? min(max(boost, 0.1), 5) : 1
    }
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    /// Restrict to these kinds; `nil` searches everything.
    public var kinds: Set<EntityKind>?
    /// Only documents carrying every one of these tags.
    public var tags: Set<String>
    public var limit: Int

    public init(text: String, kinds: Set<EntityKind>? = nil, tags: Set<String> = [], limit: Int = 30) {
        self.text = text
        self.kinds = kinds
        self.tags = tags
        self.limit = max(1, min(limit, 200))
    }
}

/// A highlighted range inside a string, in `Character` offsets.
public struct HighlightRange: Sendable, Hashable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }
}

public struct Snippet: Sendable, Hashable {
    public let text: String
    public let highlights: [HighlightRange]

    public init(text: String, highlights: [HighlightRange]) {
        self.text = text
        self.highlights = highlights
    }
}

public struct SearchResult: Sendable, Hashable, Identifiable {
    public let reference: EntityReference
    public let title: String
    public let titleHighlights: [HighlightRange]
    public let subtitle: String
    public let snippet: Snippet?
    public let tags: [String]
    public let updatedAt: Date
    public let score: Double

    public var id: String { reference.uri }
}

public struct SearchHistoryEntry: Sendable, Hashable, Identifiable {
    public let query: String
    public let lastUsed: Date
    public let useCount: Int

    public var id: String { query }
}
