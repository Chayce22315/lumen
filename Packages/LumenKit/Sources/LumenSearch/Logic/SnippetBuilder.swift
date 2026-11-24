import Foundation
import LumenFoundation

/// Builds a short excerpt around the first match and highlights every query token in it.
public enum SnippetBuilder {
    public static func snippet(for body: String, tokens: [String], radius: Int = 60) -> Snippet? {
        let text = body.collapsingWhitespace
        guard !text.isEmpty, !tokens.isEmpty else { return nil }
        guard let first = tokens.compactMap({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }

        let matchOffset = text.distance(from: text.startIndex, to: first.lowerBound)
        var startOffset = max(0, matchOffset - radius)
        var endOffset = min(text.count, matchOffset + radius * 2)
        let characters = Array(text)
        // Align to word boundaries so the excerpt doesn't start or end mid-word.
        while startOffset > 0 && !characters[startOffset - 1].isWhitespace && matchOffset - startOffset < radius + 15 {
            startOffset -= 1
        }
        while endOffset < characters.count && !characters[endOffset].isWhitespace && endOffset - matchOffset < radius * 2 + 15 {
            endOffset += 1
        }
        var excerpt = String(characters[startOffset..<endOffset]).trimmingCharacters(in: .whitespaces)
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endOffset < characters.count ? "…" : ""
        excerpt = prefix + excerpt + suffix
        return Snippet(text: excerpt, highlights: highlights(in: excerpt, tokens: tokens))
    }

    /// Character-offset ranges of every case- and diacritic-insensitive token occurrence.
    public static func highlights(in text: String, tokens: [String]) -> [HighlightRange] {
        var ranges: [HighlightRange] = []
        for token in Set(tokens) where !token.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: found.lowerBound)
                let length = text.distance(from: found.lowerBound, to: found.upperBound)
                ranges.append(HighlightRange(offset: offset, length: length))
                searchStart = found.upperBound
            }
        }
        return merge(ranges)
    }

    static func merge(_ ranges: [HighlightRange]) -> [HighlightRange] {
        let sorted = ranges.sorted { ($0.offset, $0.length) < ($1.offset, $1.length) }
        var merged: [HighlightRange] = []
        for range in sorted {
            if let last = merged.last, range.offset <= last.offset + last.length {
                let end = max(last.offset + last.length, range.offset + range.length)
                merged[merged.count - 1] = HighlightRange(offset: last.offset, length: end - last.offset)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
