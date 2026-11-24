import Foundation

extension String {
    /// Case- and diacritic-insensitive form used for matching ("Café" → "cafe").
    public var foldedForMatching: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Trims and collapses runs of whitespace and newlines into single spaces.
    public var collapsingWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The string with surrounding whitespace removed, or `nil` when nothing remains.
    public var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Word tokens after folding, for prefix matching and ranking.
    public var matchingTokens: [String] {
        foldedForMatching
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Returns at most `limit` characters, ending with an ellipsis when truncated.
    public func truncated(to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard count > limit else { return self }
        return String(prefix(max(0, limit - 1))) + "…"
    }
}
