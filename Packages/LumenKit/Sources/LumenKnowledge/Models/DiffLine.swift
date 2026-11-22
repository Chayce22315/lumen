import Foundation

/// One line of a line-based diff.
public struct DiffLine: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case unchanged
        case added
        case removed
    }

    public var kind: Kind
    public var text: String
    /// 1-based line number in the old text; `nil` for added lines.
    public var oldLineNumber: Int?
    /// 1-based line number in the new text; `nil` for removed lines.
    public var newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Counts describing a diff.
public struct DiffSummary: Sendable, Hashable {
    public var added: Int
    public var removed: Int
    public var unchanged: Int

    public init(added: Int, removed: Int, unchanged: Int) {
        self.added = added
        self.removed = removed
        self.unchanged = unchanged
    }

    public var oldLineCount: Int { unchanged + removed }
    public var newLineCount: Int { unchanged + added }
    public var isIdentical: Bool { added == 0 && removed == 0 }

    /// Share of lines touched by the change, from 0 (identical) to 1 (nothing in common):
    /// `(added + removed) / (oldLineCount + newLineCount)`.
    public var changedFraction: Double {
        let total = oldLineCount + newLineCount
        guard total > 0 else { return 0 }
        return Double(added + removed) / Double(total)
    }
}
