import Foundation

/// The block structure of a Markdown document and what is derived from it: outline, plain text,
/// word count and reading time. See `MarkdownParser` for the supported syntax.
public struct MarkdownStructure: Sendable, Hashable {
    /// Average silent reading speed used for `readingTimeMinutes`.
    public static let wordsPerMinute = 220

    public let blocks: [MarkdownBlock]

    public init(parsing markdown: String) {
        self.blocks = MarkdownParser.parse(markdown).blocks
    }

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownParser.parse(markdown).blocks
    }

    /// Headings in document order, with inline Markdown removed.
    public var outline: [MarkdownHeading] {
        blocks.enumerated().compactMap { index, block in
            guard case .heading(let level, let text) = block else { return nil }
            return MarkdownHeading(level: level, text: MarkdownInline.plainText(text), blockIndex: index)
        }
    }

    /// The document without Markdown syntax: one entry per block, separated by newlines. Code
    /// blocks contribute their code verbatim; thematic breaks contribute nothing.
    public var plainText: String {
        blocks.compactMap { block -> String? in
            switch block {
            case .thematicBreak:
                return nil
            case .codeBlock(_, let code):
                return code
            default:
                return MarkdownInline.plainText(block.text)
            }
        }.joined(separator: "\n")
    }

    /// Whitespace-separated tokens of `plainText` that contain a letter or digit.
    public var wordCount: Int {
        Self.countWords(in: plainText)
    }

    /// Minutes to read at `wordsPerMinute`, rounded up; at least 1 for any non-empty text, 0 for an
    /// empty document.
    public var readingTimeMinutes: Int {
        let text = plainText
        guard text.contains(where: { !$0.isWhitespace }) else { return 0 }
        let words = Self.countWords(in: text)
        return max(1, (words + Self.wordsPerMinute - 1) / Self.wordsPerMinute)
    }

    /// Checked and total task-list items.
    public var taskProgress: (checked: Int, total: Int) {
        var checked = 0
        var total = 0
        for case .listItem(_, _, _, _, let checkbox?) in blocks {
            total += 1
            if checkbox == .checked { checked += 1 }
        }
        return (checked, total)
    }

    static func countWords(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }

    // MARK: - Convenience

    public static func plainText(_ markdown: String) -> String {
        MarkdownStructure(parsing: markdown).plainText
    }

    public static func wordCount(_ markdown: String) -> Int {
        MarkdownStructure(parsing: markdown).wordCount
    }

    // MARK: - Checkboxes

    /// Number of task-list checkboxes in `markdown` (outside code blocks).
    public static func checkboxCount(in markdown: String) -> Int {
        MarkdownParser.parse(markdown).checkboxes.count
    }

    /// `markdown` with the checkbox of the `index`-th task item (0-based, document order, code blocks
    /// excluded) toggled between `[ ]` and `[x]`. Everything else, line endings included, is left
    /// byte for byte. Returns `nil` when there is no such checkbox.
    public static func togglingCheckbox(at index: Int, in markdown: String) -> String? {
        let checkboxes = MarkdownParser.parse(markdown).checkboxes
        guard checkboxes.indices.contains(index) else { return nil }
        let range = checkboxes[index]
        let replacement = markdown[range] == " " ? "x" : " "
        var result = markdown
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
