import Foundation
import LumenFoundation

/// Turns free text into a safe FTS5 `MATCH` expression.
///
/// User input never reaches FTS5 syntax directly: every token is reduced to letters and digits,
/// quoted, and given a prefix wildcard, then the tokens are AND-ed. "rép rev" → `"rep"* "rev"*`.
public enum FTSQueryBuilder {
    public static let maximumTokens = 12

    public static func tokens(for text: String) -> [String] {
        Array(text.matchingTokens.prefix(maximumTokens))
    }

    /// `nil` when the text contains nothing searchable.
    public static func matchExpression(for text: String) -> String? {
        let tokens = tokens(for: text)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
