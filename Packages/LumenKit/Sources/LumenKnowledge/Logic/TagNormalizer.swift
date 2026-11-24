import Foundation
import LumenFoundation

/// Canonical form of tags, shared by explicit tags and `#hashtags`.
///
/// A tag is trimmed, stripped of leading `#` (and whitespace between them), lowercased, has runs
/// of internal whitespace replaced by a single `-`, and is cut to `maximumLength` characters.
/// Empty results are rejected.
public enum TagNormalizer {
    public static let maximumLength = 64

    /// The normalized tag, or `nil` when nothing remains.
    public static func normalize(_ raw: String) -> String? {
        // Leading hashes and the whitespace around them ("# tag", "## #tag") are not part of the tag.
        let text = raw.drop(while: { $0 == "#" || $0.isWhitespace })
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        var tag = words.joined(separator: "-")
        if tag.count > maximumLength {
            tag = String(tag.prefix(maximumLength))
            // Cutting may leave a dangling separator from collapsed whitespace.
            while tag.last == "-" {
                tag.removeLast()
            }
        }
        return tag.isEmpty ? nil : tag
    }

    /// Normalizes every tag, drops empty ones and removes duplicates, keeping first occurrences.
    public static func normalize(_ tags: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            guard let tag = normalize(raw), seen.insert(tag).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// The normalized tag; throws a `ValidationError` when the input normalizes to nothing.
    public static func validated(_ raw: String, field: String = "tag") throws -> String {
        guard let tag = normalize(raw) else {
            throw ValidationError(field: field, reason: "A tag needs at least one letter or number.")
        }
        return tag
    }

    /// Whether `tag` can be written as a `#hashtag` (letters, digits, `-` and `_`, with at least
    /// one letter), so that it survives being parsed back out of a note body.
    public static func isHashtagCompatible(_ tag: String) -> Bool {
        !tag.isEmpty
            && tag.allSatisfy(WikiLinkParser.isHashtagCharacter)
            && tag.contains(where: \.isLetter)
    }
}
