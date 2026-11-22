import Foundation
import Testing
import LumenKnowledge

@Suite("LineDiff")
struct LineDiffTests {
    @Test("identical texts are all unchanged")
    func identical() {
        let diff = LineDiff(old: "a\nb\nc", new: "a\nb\nc")
        #expect(diff.lines.map(\.kind) == [.unchanged, .unchanged, .unchanged])
        #expect(diff.lines.map(\.oldLineNumber) == [1, 2, 3])
        #expect(diff.lines.map(\.newLineNumber) == [1, 2, 3])
        #expect(diff.summary.isIdentical)
        #expect(diff.summary.changedFraction == 0)
        #expect(diff.changes.isEmpty)
        #expect(!diff.isApproximate)
    }

    @Test("empty inputs")
    func emptyInputs() {
        #expect(LineDiff(old: "", new: "").lines.isEmpty)
        #expect(LineDiff(old: "", new: "").summary.changedFraction == 0)

        let added = LineDiff(old: "", new: "x\ny")
        #expect(added.lines == [
            DiffLine(kind: .added, text: "x", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(kind: .added, text: "y", oldLineNumber: nil, newLineNumber: 2),
        ])
        #expect(added.summary.changedFraction == 1)

        let removed = LineDiff(old: "x\ny", new: "")
        #expect(removed.lines.map(\.kind) == [.removed, .removed])
        #expect(removed.lines.map(\.oldLineNumber) == [1, 2])
        #expect(removed.summary == DiffSummary(added: 0, removed: 2, unchanged: 0))
    }

    @Test("a replaced line shows as removed then added with line numbers")
    func replacement() {
        let diff = LineDiff(old: "a\nb\nc", new: "a\nB\nc")
        #expect(diff.lines == [
            DiffLine(kind: .unchanged, text: "a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(kind: .removed, text: "b", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(kind: .added, text: "B", oldLineNumber: nil, newLineNumber: 2),
            DiffLine(kind: .unchanged, text: "c", oldLineNumber: 3, newLineNumber: 3),
        ])
        #expect(diff.summary.changedFraction == 2.0 / 6.0)
    }

    @Test("insertions and deletions shift line numbers correctly")
    func insertionsAndDeletions() {
        let diff = LineDiff(old: "one\ntwo\nthree\nfour", new: "zero\none\nthree\nfour\nfive")
        #expect(diff.lines == [
            DiffLine(kind: .added, text: "zero", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(kind: .unchanged, text: "one", oldLineNumber: 1, newLineNumber: 2),
            DiffLine(kind: .removed, text: "two", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(kind: .unchanged, text: "three", oldLineNumber: 3, newLineNumber: 3),
            DiffLine(kind: .unchanged, text: "four", oldLineNumber: 4, newLineNumber: 4),
            DiffLine(kind: .added, text: "five", oldLineNumber: nil, newLineNumber: 5),
        ])
    }

    @Test("within a changed region all removals precede additions")
    func groupedRegions() {
        let diff = LineDiff(old: "keep\nx1\nx2\nx3\nend", new: "keep\ny1\ny2\nend")
        #expect(diff.lines.map(\.kind) == [.unchanged, .removed, .removed, .removed, .added, .added, .unchanged])
        #expect(diff.lines.map(\.text) == ["keep", "x1", "x2", "x3", "y1", "y2", "end"])
    }

    @Test("line terminators: CRLF, CR and a final newline do not create differences")
    func lineTerminators() {
        #expect(LineDiff.lines(of: "a\r\nb\rc\n") == ["a", "b", "c"])
        #expect(LineDiff.lines(of: "a\n\n") == ["a", ""])
        #expect(LineDiff.lines(of: "\n") == [""])
        #expect(LineDiff(old: "a\r\nb\r\n", new: "a\nb").summary.isIdentical)
    }

    @Test("random inputs: the script rebuilds both sides and is minimal (matches LCS)")
    func propertyMinimal() {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let alphabet = ["a", "b", "c", "d", ""]
        for round in 0..<400 {
            let old = (0..<Int.random(in: 0...24, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? "a" }
            let new = (0..<Int.random(in: 0...24, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? "a" }
            let diff = LineDiff(oldLines: old, newLines: new)

            let rebuiltOld = diff.lines.filter { $0.kind != .added }.map(\.text)
            let rebuiltNew = diff.lines.filter { $0.kind != .removed }.map(\.text)
            #expect(rebuiltOld == old, "round \(round)")
            #expect(rebuiltNew == new, "round \(round)")
            #expect(diff.summary.unchanged == Self.lcsLength(old, new), "round \(round)")
            #expect(diff.lines.compactMap(\.oldLineNumber) == old.indices.map { $0 + 1 })
            #expect(diff.lines.compactMap(\.newLineNumber) == new.indices.map { $0 + 1 })
        }
    }

    @Test("large inputs with scattered edits stay exact")
    func largeInput() {
        let old = (0..<4_000).map { "line \($0)" }
        var new = old
        new[100] = "changed 100"
        new[2_000] = "changed 2000"
        new.remove(at: 3_500)
        new.insert("inserted", at: 10)
        let diff = LineDiff(oldLines: old, newLines: new)
        #expect(!diff.isApproximate)
        #expect(diff.summary == DiffSummary(added: 3, removed: 3, unchanged: 3_997))
    }

    @Test("inputs beyond the line-product bound fall back to a whole replacement")
    func boundedFallback() {
        let small = LineDiff(old: "same\na\nb\nc\nsame", new: "same\nb\nc\nd\nsame", maximumLineProduct: 4)
        #expect(small.isApproximate)
        #expect(small.lines.map(\.kind) == [.unchanged, .removed, .removed, .removed, .added, .added, .added, .unchanged])

        let exact = LineDiff(old: "same\na\nb\nc\nsame", new: "same\nb\nc\nd\nsame")
        #expect(!exact.isApproximate)
        #expect(exact.summary == DiffSummary(added: 1, removed: 1, unchanged: 4))

        let old = (0..<5_001).map { "old \($0)" }
        let new = (0..<5_001).map { "new \($0)" }
        let huge = LineDiff(oldLines: old, newLines: new)
        #expect(huge.isApproximate)
        #expect(huge.summary == DiffSummary(added: 5_001, removed: 5_001, unchanged: 0))
    }

    static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}
