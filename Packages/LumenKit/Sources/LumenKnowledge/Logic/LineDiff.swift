import Foundation

/// A line-based diff between two texts.
///
/// Lines common to the start and end are matched first; the remaining middle is diffed with Myers'
/// algorithm, which yields a minimal edit script. When the middle is larger than
/// `maximumLineProduct` (old lines × new lines, 5 000 × 5 000 by default) it is reported as a
/// whole replacement instead, bounding time and memory; `isApproximate` tells the caller.
///
/// Within each changed region removed lines come before added lines.
public struct LineDiff: Sendable, Hashable {
    public static let defaultMaximumLineProduct = 5_000 * 5_000

    public let lines: [DiffLine]
    public let summary: DiffSummary
    /// True when the input exceeded `maximumLineProduct` and the middle was treated as replaced.
    public let isApproximate: Bool

    public init(old: String, new: String, maximumLineProduct: Int = LineDiff.defaultMaximumLineProduct) {
        self.init(oldLines: Self.lines(of: old), newLines: Self.lines(of: new), maximumLineProduct: maximumLineProduct)
    }

    public init(oldLines: [String], newLines: [String], maximumLineProduct: Int = LineDiff.defaultMaximumLineProduct) {
        var symbols: [String: Int] = [:]
        func symbol(_ line: String) -> Int {
            if let existing = symbols[line] { return existing }
            let next = symbols.count
            symbols[line] = next
            return next
        }
        let old = oldLines.map(symbol)
        let new = newLines.map(symbol)

        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])

        var operations = [MyersDiff.Operation](repeating: .equal, count: prefix)
        let product = oldMiddle.count.multipliedReportingOverflow(by: newMiddle.count)
        let approximate = product.overflow || product.partialValue > max(0, maximumLineProduct)
        if approximate {
            operations += [MyersDiff.Operation](repeating: .delete, count: oldMiddle.count)
            operations += [MyersDiff.Operation](repeating: .insert, count: newMiddle.count)
        } else {
            operations += MyersDiff.operations(old: oldMiddle, new: newMiddle)
        }
        operations += [MyersDiff.Operation](repeating: .equal, count: suffix)

        let (lines, summary) = Self.render(operations, oldLines: oldLines, newLines: newLines)
        self.lines = lines
        self.summary = summary
        self.isApproximate = approximate
    }

    /// Splits text into lines on `\n`, `\r\n` or `\r`. A final line terminator does not start an
    /// extra empty line, and an empty text has no lines.
    public static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = MarkdownSource.lines(of: text).map { String($0.text) }
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Changed lines only.
    public var changes: [DiffLine] { lines.filter { $0.kind != .unchanged } }

    private static func render(
        _ operations: [MyersDiff.Operation],
        oldLines: [String],
        newLines: [String]
    ) -> ([DiffLine], DiffSummary) {
        var lines: [DiffLine] = []
        lines.reserveCapacity(operations.count)
        var removedRun: [DiffLine] = []
        var addedRun: [DiffLine] = []
        var oldIndex = 0, newIndex = 0
        var added = 0, removed = 0, unchanged = 0

        func flushRuns() {
            lines += removedRun
            lines += addedRun
            removedRun.removeAll(keepingCapacity: true)
            addedRun.removeAll(keepingCapacity: true)
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushRuns()
                lines.append(DiffLine(kind: .unchanged, text: oldLines[oldIndex], oldLineNumber: oldIndex + 1, newLineNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
                unchanged += 1
            case .delete:
                removedRun.append(DiffLine(kind: .removed, text: oldLines[oldIndex], oldLineNumber: oldIndex + 1, newLineNumber: nil))
                oldIndex += 1
                removed += 1
            case .insert:
                addedRun.append(DiffLine(kind: .added, text: newLines[newIndex], oldLineNumber: nil, newLineNumber: newIndex + 1))
                newIndex += 1
                added += 1
            }
        }
        flushRuns()
        return (lines, DiffSummary(added: added, removed: removed, unchanged: unchanged))
    }
}
