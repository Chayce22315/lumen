import Foundation

/// One line of Markdown source. `text` excludes the line terminator (`\n`, `\r\n` or `\r`) and
/// shares indices with the original string, so ranges found in it are valid in the source.
struct MarkdownSourceLine {
    let text: Substring

    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
}

/// An opening code fence (```` ``` ```` or `~~~`).
struct MarkdownFence {
    let character: Character
    let length: Int
    /// Columns of indentation before the fence; removed from content lines.
    let indent: Int
    let info: String

    var language: String? {
        info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }
}

/// Line-level scanning shared by the block parser, the link parser and checkbox toggling.
enum MarkdownSource {
    static func lines(of text: String) -> [MarkdownSourceLine] {
        var lines: [MarkdownSourceLine] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r\n" || character == "\r" {
                lines.append(MarkdownSourceLine(text: text[lineStart..<index]))
                index = text.index(after: index)
                lineStart = index
            } else {
                index = text.index(after: index)
            }
        }
        lines.append(MarkdownSourceLine(text: text[lineStart..<text.endIndex]))
        return lines
    }

    static func isSpaceOrTab(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    /// Leading indentation in columns (a tab advances to the next multiple of 4) and the index
    /// of the first non-indentation character.
    static func indentation(of line: Substring) -> (columns: Int, contentStart: Substring.Index) {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - (columns % 4)
            } else {
                break
            }
            index = line.index(after: index)
        }
        return (columns, index)
    }

    /// Removes up to `columns` columns of leading spaces and tabs.
    static func removingIndentation(_ line: Substring, upTo columns: Int) -> Substring {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            let character = line[index]
            if character == " " {
                removed += 1
            } else if character == "\t" {
                removed += 4 - (removed % 4)
            } else {
                break
            }
            index = line.index(after: index)
        }
        return line[index...]
    }

    static func openingFence(in line: Substring) -> MarkdownFence? {
        let (columns, start) = indentation(of: line)
        guard columns <= 3 else { return nil }
        let rest = line[start...]
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let info = rest[run.endIndex...].trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return MarkdownFence(character: first, length: run.count, indent: columns, info: info)
    }

    static func isClosingFence(_ line: Substring, for fence: MarkdownFence) -> Bool {
        let (columns, start) = indentation(of: line)
        guard columns <= 3 else { return false }
        let rest = line[start...]
        let run = rest.prefix(while: { $0 == fence.character })
        guard run.count >= fence.length else { return false }
        return rest[run.endIndex...].allSatisfy(isSpaceOrTab)
    }

    /// Marks which lines belong to fenced code blocks (fence lines included).
    static func fencedLineMask(_ lines: [MarkdownSourceLine]) -> [Bool] {
        var mask = [Bool](repeating: false, count: lines.count)
        var open: MarkdownFence?
        for (index, line) in lines.enumerated() {
            if let fence = open {
                mask[index] = true
                if isClosingFence(line.text, for: fence) {
                    open = nil
                }
            } else if let fence = openingFence(in: line.text) {
                mask[index] = true
                open = fence
            }
        }
        return mask
    }

    /// Ranges of inline code spans (backticks included) within one line. A run of N backticks
    /// opens a span that closes at the next run of exactly N backticks; unmatched runs are literal.
    static func codeSpans(in line: Substring) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "`", !isEscaped(index, in: line) else {
                index = line.index(after: index)
                continue
            }
            let openStart = index
            let openEnd = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
            let length = line.distance(from: openStart, to: openEnd)
            var search = openEnd
            var closed = false
            while search < line.endIndex {
                guard line[search] == "`" else {
                    search = line.index(after: search)
                    continue
                }
                let runEnd = line[search...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
                if line.distance(from: search, to: runEnd) == length {
                    spans.append(openStart..<runEnd)
                    index = runEnd
                    closed = true
                    break
                }
                search = runEnd
            }
            if !closed {
                index = openEnd
            }
        }
        return spans
    }

    /// Whether the character at `index` is preceded by an odd number of backslashes.
    static func isEscaped(_ index: Substring.Index, in line: Substring) -> Bool {
        var count = 0
        var cursor = index
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else { break }
            count += 1
            cursor = previous
        }
        return count % 2 == 1
    }
}
