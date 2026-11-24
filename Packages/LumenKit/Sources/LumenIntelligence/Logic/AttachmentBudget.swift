import Foundation
import LumenFoundation

/// How much of each attachment's text is sent with a message.
public enum AttachmentBudget {
    /// Splits `limit` characters among items of the given `lengths`: each item gets an equal
    /// share, and what a short item doesn't need is handed on to the longer ones. The result has
    /// one entry per input, in input order, each at most that item's length.
    public static func allocate(lengths: [Int], limit: Int) -> [Int] {
        var allocation = Array(repeating: 0, count: lengths.count)
        var remaining = max(0, limit)
        let order = lengths.indices.sorted { lengths[$0] < lengths[$1] }
        for (position, index) in order.enumerated() {
            let share = remaining / (order.count - position)
            let granted = min(max(0, lengths[index]), share)
            allocation[index] = granted
            remaining -= granted
        }
        return allocation
    }

    /// Characters available for one message's attachments: the configured ceiling, but never more
    /// than half of the history budget (estimated tokens × 4 characters), so a large attachment
    /// can't push the conversation itself out of the context window.
    public static func characterLimit(historyBudgetTokens: Int, ceiling: Int) -> Int {
        max(0, min(ceiling, historyBudgetTokens * 4 / 2))
    }
}

/// How attachments are presented to the model: one delimited block per item, ahead of the
/// user's own text.
public enum AttachmentPrompt {
    /// The text block for `attachment`. `content` is the item's current text, or `nil` when it no
    /// longer exists; the text is cut to the characters recorded when the message was sent.
    public static func block(for attachment: MessageAttachment, content: AttachmentContent?) -> String {
        let title = sanitized(content?.title ?? attachment.title)
        guard let content else {
            return "<attachment title=\"\(title)\" unavailable=\"true\">This item was deleted or no longer has text.</attachment>"
        }
        let text = String(content.text.prefix(attachment.includedCharacters))
        var attributes = "kind=\"\(sanitized(content.kind))\" title=\"\(title)\""
        if text.count < content.text.count {
            attributes += " truncated=\"first \(text.count) of \(content.text.count) characters\""
        }
        return "<attachment \(attributes)>\n\(text)\n</attachment>"
    }

    /// Attribute values stay on one line and never close the attribute early.
    static func sanitized(_ value: String) -> String {
        value.collapsingWhitespace.replacingOccurrences(of: "\"", with: "'")
    }
}
