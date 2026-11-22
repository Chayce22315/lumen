import Foundation
import LumenFoundation

/// How a note's `tags` combine explicit tags with the `#hashtags` of its body.
///
/// A note's tags are its explicit tags followed by the body's hashtags, normalized and without
/// duplicates. When the body changes, tags that came from hashtags of the previous body are
/// treated as derived: removing the hashtag removes the tag. (A tag that was set explicitly *and*
/// written as a hashtag is therefore removed together with its last hashtag.)
public enum NoteTagging {
    public static func tags(explicit: [String], body: String) -> [String] {
        TagNormalizer.normalize(explicit + WikiLinkParser.hashtags(in: body).map(\.normalized))
    }

    /// The tags in `tags` that do not come from a hashtag in `body`.
    public static func explicitTags(_ tags: [String], body: String) -> [String] {
        let derived = Set(WikiLinkParser.hashtags(in: body).map(\.normalized))
        return TagNormalizer.normalize(tags).filter { !derived.contains($0) }
    }

    /// The tags after the body changed from `previousBody` to `newBody`.
    public static func retag(_ tags: [String], previousBody: String, newBody: String) -> [String] {
        Self.tags(explicit: explicitTags(tags, body: previousBody), body: newBody)
    }

    /// `body` with every hashtag whose normalized tag is in `sources` replaced by `#target`.
    /// Hashtags inside code are not touched (the parser does not report them).
    public static func rewritingHashtags(in body: String, replacing sources: Set<String>, with target: String) -> String {
        let matches = WikiLinkParser.hashtags(in: body).filter { sources.contains($0.normalized) }
        guard !matches.isEmpty else { return body }
        var result = ""
        result.reserveCapacity(body.utf8.count)
        var cursor = body.startIndex
        for match in matches {
            result += body[cursor..<match.range.lowerBound]
            result += "#" + target
            cursor = match.range.upperBound
        }
        result += body[cursor...]
        return result
    }

    /// Whether `body` contains a hashtag for any of `tags`.
    public static func containsHashtag(for tags: Set<String>, in body: String) -> Bool {
        WikiLinkParser.hashtags(in: body).contains { tags.contains($0.normalized) }
    }
}

/// Matching of `[[Title]]` links against note titles.
public enum LinkTitle {
    /// Comparison key: whitespace collapsed, then case-, diacritic- and width-folded
    /// (`foldedForMatching`). "Café  Notes" and "cafe notes" share a key.
    public static func matchingKey(_ title: String) -> String {
        title.collapsingWhitespace.foldedForMatching
    }
}
