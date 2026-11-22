import Foundation

/// State of a task-list checkbox (`- [ ]` / `- [x]`).
public enum MarkdownCheckbox: String, Sendable, Hashable, Codable {
    case unchecked
    case checked

    public var toggled: MarkdownCheckbox { self == .checked ? .unchecked : .checked }
}

/// A block-level element of a Markdown document.
///
/// Texts are the raw inline Markdown of the block (emphasis, links and code spans are kept), with
/// the block's own syntax (heading hashes, list markers, quote markers, fences) removed. Lines of
/// multi-line blocks are joined with `\n`.
public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    /// `depth` is 0 for top-level items; `number` is set for ordered items (`3.` → 3).
    case listItem(ordered: Bool, number: Int?, depth: Int, text: String, checkbox: MarkdownCheckbox?)
    case blockquote(text: String)
    case codeBlock(language: String?, code: String)
    case thematicBreak

    /// The block's inline text, or the code for code blocks; empty for thematic breaks.
    public var text: String {
        switch self {
        case .heading(_, let text), .paragraph(let text), .blockquote(let text):
            return text
        case .listItem(_, _, _, let text, _):
            return text
        case .codeBlock(_, let code):
            return code
        case .thematicBreak:
            return ""
        }
    }
}

/// One entry of a document outline.
public struct MarkdownHeading: Sendable, Hashable {
    public var level: Int
    /// Heading text with inline Markdown removed.
    public var text: String
    /// Index of the heading within `MarkdownStructure.blocks`.
    public var blockIndex: Int

    public init(level: Int, text: String, blockIndex: Int) {
        self.level = level
        self.text = text
        self.blockIndex = blockIndex
    }
}
