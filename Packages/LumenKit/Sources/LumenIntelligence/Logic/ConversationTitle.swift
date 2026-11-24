import Foundation
import LumenFoundation

/// Titles derived from the first user message, without an extra model call.
public enum ConversationTitle {
    public static let maximumLength = 60

    /// The message's whitespace collapsed to single spaces, cut at a word boundary to at most
    /// `maximumLength` characters (ellipsis included) when longer.
    public static func make(from text: String, maximumLength: Int = ConversationTitle.maximumLength) -> String {
        let collapsed = text.collapsingWhitespace
        guard maximumLength > 1 else { return String(collapsed.prefix(max(0, maximumLength))) }
        guard collapsed.count > maximumLength else { return collapsed }
        var cut = String(collapsed.prefix(maximumLength - 1))
        // Prefer ending on a whole word when one ends reasonably late.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maximumLength / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last.isWhitespace || ",;:-–—".contains(last) {
            cut.removeLast()
        }
        return cut + "…"
    }
}
