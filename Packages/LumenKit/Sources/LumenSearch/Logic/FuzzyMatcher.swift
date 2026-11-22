import Foundation
import LumenFoundation

/// Subsequence fuzzy matching for short strings (command titles, entity titles).
///
/// Scores reward contiguous runs, matches at word starts and matches near the start; a candidate
/// that does not contain every query character in order does not match at all.
public enum FuzzyMatcher {
    public struct Match: Sendable, Hashable {
        public let score: Double
        /// Matched character offsets in the candidate, ascending.
        public let indices: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.foldedForMatching.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let original = Array(candidate)
        let hay = original.map { String($0).foldedForMatching.first ?? $0 }
        guard needle.count <= hay.count else { return nil }

        var indices: [Int] = []
        var score = 0.0
        var searchFrom = 0
        var previous: Int?
        for character in needle {
            guard let found = (searchFrom..<hay.count).first(where: { hay[$0] == character }) else { return nil }
            indices.append(found)
            var points = 1.0
            if let previous, found == previous + 1 { points += 2.0 }
            if found == 0 || !(original[found - 1].isLetter || original[found - 1].isNumber) { points += 1.5 }
            if found < 3 { points += 0.5 }
            score += points
            previous = found
            searchFrom = found + 1
        }
        // Prefer shorter candidates for equal matches.
        score -= Double(hay.count - needle.count) * 0.01
        return Match(score: score, indices: indices)
    }

    /// Collapses matched indices into highlight ranges.
    public static func highlights(for indices: [Int]) -> [HighlightRange] {
        var ranges: [HighlightRange] = []
        var start: Int?
        var length = 0
        for index in indices {
            if let current = start, current + length == index {
                length += 1
            } else {
                if let current = start { ranges.append(HighlightRange(offset: current, length: length)) }
                start = index
                length = 1
            }
        }
        if let current = start { ranges.append(HighlightRange(offset: current, length: length)) }
        return ranges
    }
}
