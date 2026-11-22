import Foundation

/// Line-based block parser behind `MarkdownStructure`.
///
/// Supported: ATX headings (`#`–`######`, optional closing hashes), setext headings (`===` / `---`
/// under a paragraph line), paragraphs, bullet (`-`, `*`, `+`) and ordered (`1.`, `1)`) list items
/// with task checkboxes and nesting by indentation, blockquotes (consecutive and lazily continued
/// lines merge), fenced code blocks (```` ``` ```` / `~~~`, unclosed fences run to the end) and
/// thematic breaks (`---`, `***`, `___`, spaced variants).
struct MarkdownParser {
    struct Result {
        var blocks: [MarkdownBlock] = []
        /// Range of the state character (between `[` and `]`) of every task checkbox, in order.
        var checkboxes: [Range<String.Index>] = []
    }

    private struct OpenItem {
        var ordered: Bool
        var number: Int?
        var depth: Int
        var lines: [String]
        var checkbox: MarkdownCheckbox?
    }

    private struct OpenFence {
        var fence: MarkdownFence
        var lines: [String]
    }

    struct ListMarker {
        var ordered: Bool
        var number: Int?
        var indent: Int
        var checkbox: MarkdownCheckbox?
        var checkboxRange: Range<String.Index>?
        var text: String
    }

    private var result = Result()
    private var paragraph: [String] = []
    private var quote: [String] = []
    private var item: OpenItem?
    private var fence: OpenFence?
    /// Indentation of the list items that enclose the next item, innermost last.
    private var listIndents: [Int] = []

    static func parse(_ text: String) -> Result {
        var parser = MarkdownParser()
        for line in MarkdownSource.lines(of: text) {
            parser.consume(line)
        }
        parser.finish()
        return parser.result
    }

    // MARK: - Line handling

    private mutating func consume(_ line: MarkdownSourceLine) {
        let text = line.text
        if var open = fence {
            if MarkdownSource.isClosingFence(text, for: open.fence) {
                result.blocks.append(.codeBlock(language: open.fence.language, code: open.lines.joined(separator: "\n")))
                fence = nil
            } else {
                open.lines.append(String(MarkdownSource.removingIndentation(text, upTo: open.fence.indent)))
                fence = open
            }
            return
        }

        if line.isBlank {
            flushParagraph()
            flushQuote()
            flushItem()
            return
        }

        if let opening = MarkdownSource.openingFence(in: text) {
            closeAll()
            fence = OpenFence(fence: opening, lines: [])
            return
        }

        if let heading = Self.atxHeading(text) {
            closeAll()
            result.blocks.append(.heading(level: heading.level, text: heading.text))
            return
        }

        if !paragraph.isEmpty, let level = Self.setextLevel(text) {
            let headingText = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            closeAll()
            result.blocks.append(.heading(level: level, text: headingText))
            return
        }

        if Self.isThematicBreak(text) {
            closeAll()
            result.blocks.append(.thematicBreak)
            return
        }

        if let content = Self.quoteContent(text) {
            flushParagraph()
            flushItem()
            listIndents.removeAll()
            quote.append(content.trimmingCharacters(in: .whitespaces))
            return
        }

        if let marker = Self.listMarker(text) {
            flushParagraph()
            flushQuote()
            flushItem()
            while let last = listIndents.last, last >= marker.indent {
                listIndents.removeLast()
            }
            let depth = listIndents.count
            listIndents.append(marker.indent)
            if let range = marker.checkboxRange {
                result.checkboxes.append(range)
            }
            item = OpenItem(
                ordered: marker.ordered,
                number: marker.number,
                depth: depth,
                lines: [marker.text],
                checkbox: marker.checkbox
            )
            return
        }

        let content = text.trimmingCharacters(in: .whitespaces)
        if !quote.isEmpty {
            // Lazy continuation: a plain line right after a quote line continues the quote.
            quote.append(content)
        } else if var open = item {
            // A plain line right after an item continues that item's text.
            open.lines.append(content)
            item = open
        } else {
            if paragraph.isEmpty {
                listIndents.removeAll()
            }
            paragraph.append(content)
        }
    }

    private mutating func finish() {
        if let open = fence {
            result.blocks.append(.codeBlock(language: open.fence.language, code: open.lines.joined(separator: "\n")))
            fence = nil
        }
        closeAll()
    }

    private mutating func closeAll() {
        flushParagraph()
        flushQuote()
        flushItem()
        listIndents.removeAll()
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        result.blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
        paragraph.removeAll()
    }

    private mutating func flushQuote() {
        guard !quote.isEmpty else { return }
        result.blocks.append(.blockquote(text: quote.joined(separator: "\n")))
        quote.removeAll()
    }

    private mutating func flushItem() {
        guard let open = item else { return }
        result.blocks.append(.listItem(
            ordered: open.ordered,
            number: open.number,
            depth: open.depth,
            text: open.lines.joined(separator: "\n"),
            checkbox: open.checkbox
        ))
        item = nil
    }

    // MARK: - Line classification

    static func atxHeading(_ line: Substring) -> (level: Int, text: String)? {
        let (columns, start) = MarkdownSource.indentation(of: line)
        guard columns <= 3 else { return nil }
        let rest = line[start...]
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let after = rest[hashes.endIndex...]
        if let first = after.first, !MarkdownSource.isSpaceOrTab(first) { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: trailing hashes that stand alone ("Title ##").
        let trailing = text.reversed().prefix(while: { $0 == "#" }).count
        if trailing > 0 {
            let remainder = text.dropLast(trailing)
            if remainder.isEmpty || remainder.last.map(MarkdownSource.isSpaceOrTab) == true {
                text = remainder.trimmingCharacters(in: .whitespaces)
            }
        }
        return (hashes.count, text)
    }

    static func setextLevel(_ line: Substring) -> Int? {
        let (columns, start) = MarkdownSource.indentation(of: line)
        guard columns <= 3 else { return nil }
        let rest = line[start...].trimmingCharacters(in: .whitespaces)
        guard let first = rest.first, first == "=" || first == "-" else { return nil }
        guard rest.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isThematicBreak(_ line: Substring) -> Bool {
        let (columns, start) = MarkdownSource.indentation(of: line)
        guard columns <= 3 else { return false }
        let rest = line[start...]
        guard let first = rest.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for character in rest {
            if character == first {
                count += 1
            } else if !MarkdownSource.isSpaceOrTab(character) {
                return false
            }
        }
        return count >= 3
    }

    static func quoteContent(_ line: Substring) -> Substring? {
        let (columns, start) = MarkdownSource.indentation(of: line)
        guard columns <= 3, start < line.endIndex, line[start] == ">" else { return nil }
        var content = line[line.index(after: start)...]
        if let first = content.first, MarkdownSource.isSpaceOrTab(first) {
            content = content.dropFirst()
        }
        return content
    }

    static func listMarker(_ line: Substring) -> ListMarker? {
        let (columns, start) = MarkdownSource.indentation(of: line)
        let rest = line[start...]
        guard let first = rest.first else { return nil }
        var ordered = false
        var number: Int?
        let afterMarker: Substring.Index
        if first == "-" || first == "*" || first == "+" {
            afterMarker = rest.index(after: rest.startIndex)
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count <= 9, digits.endIndex < rest.endIndex else { return nil }
            let delimiter = rest[digits.endIndex]
            guard delimiter == "." || delimiter == ")" else { return nil }
            ordered = true
            number = Int(digits)
            afterMarker = rest.index(after: digits.endIndex)
        } else {
            return nil
        }
        if afterMarker < rest.endIndex, !MarkdownSource.isSpaceOrTab(rest[afterMarker]) {
            return nil
        }
        var content = rest[afterMarker...].drop(while: MarkdownSource.isSpaceOrTab)
        var checkbox: MarkdownCheckbox?
        var checkboxRange: Range<String.Index>?
        if content.first == "[", content.count >= 3 {
            let stateIndex = content.index(after: content.startIndex)
            let closeIndex = content.index(after: stateIndex)
            let state = content[stateIndex]
            if content[closeIndex] == "]", state == " " || state == "x" || state == "X" {
                let afterBox = content.index(after: closeIndex)
                if afterBox == content.endIndex || MarkdownSource.isSpaceOrTab(content[afterBox]) {
                    checkbox = state == " " ? .unchecked : .checked
                    checkboxRange = stateIndex..<closeIndex
                    content = content[afterBox...].drop(while: MarkdownSource.isSpaceOrTab)
                }
            }
        }
        return ListMarker(
            ordered: ordered,
            number: number,
            indent: columns,
            checkbox: checkbox,
            checkboxRange: checkboxRange,
            text: content.trimmingCharacters(in: .whitespaces)
        )
    }
}
