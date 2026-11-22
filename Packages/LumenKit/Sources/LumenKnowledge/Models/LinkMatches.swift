import Foundation
import LumenFoundation

/// A `[[…]]` link found by `WikiLinkParser`.
public struct WikiLinkMatch: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// `[[Title]]`: the trimmed title as written.
        case title(String)
        /// `[[kind:UUID]]`: an explicit entity reference.
        case entity(EntityReference)
    }

    public var target: Target
    /// Text after `|`, trimmed; `nil` when absent or empty.
    public var alias: String?
    /// Range of the whole link, brackets included, in the parsed text.
    public var range: Range<String.Index>
    /// The link exactly as written, brackets included.
    public var rawText: String

    public init(target: Target, alias: String?, range: Range<String.Index>, rawText: String) {
        self.target = target
        self.alias = alias
        self.range = range
        self.rawText = rawText
    }

    /// The title for `[[Title]]` links, or the reference text for mentions.
    public var targetText: String {
        switch target {
        case .title(let title): return title
        case .entity(let reference): return reference.uri
        }
    }
}

/// A `#hashtag` found by `WikiLinkParser`.
public struct HashtagMatch: Sendable, Hashable {
    /// The tag as written, without `#`.
    public var tag: String
    /// `TagNormalizer` form of `tag`.
    public var normalized: String
    /// Range of the hashtag, `#` included, in the parsed text.
    public var range: Range<String.Index>

    public init(tag: String, normalized: String, range: Range<String.Index>) {
        self.tag = tag
        self.normalized = normalized
        self.range = range
    }
}

/// Everything `WikiLinkParser.parse(_:)` finds, each list in source order.
public struct ParsedLinks: Sendable, Hashable {
    public var links: [WikiLinkMatch]
    public var hashtags: [HashtagMatch]

    public init(links: [WikiLinkMatch] = [], hashtags: [HashtagMatch] = []) {
        self.links = links
        self.hashtags = hashtags
    }

    /// Normalized hashtags without duplicates, in order of first appearance.
    public var normalizedTags: [String] {
        TagNormalizer.normalize(hashtags.map(\.normalized))
    }
}
