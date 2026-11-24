import Foundation
import Testing
import LumenKnowledge

@Suite("MarkdownStructure blocks")
struct MarkdownStructureTests {
    func blocks(_ markdown: String) -> [MarkdownBlock] {
        MarkdownStructure.parse(markdown)
    }

    @Test("ATX headings: levels 1–6, closing hashes, indentation limits")
    func atxHeadings() {
        let parsed = blocks("""
            # One
            ## Two ##
            ### Three #not-closing
            #### C#
            #####
               ###### Six
            ####### Seven
            #NoSpace
                # Indented four
            """)
        #expect(parsed == [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three #not-closing"),
            .heading(level: 4, text: "C#"),
            .heading(level: 5, text: ""),
            .heading(level: 6, text: "Six"),
            .paragraph(text: "####### Seven\n#NoSpace\n# Indented four"),
        ])
    }

    @Test("setext headings underline a paragraph")
    func setextHeadings() {
        #expect(blocks("Title\n=====\n\nSubtitle\n---\ntext") == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Subtitle"),
            .paragraph(text: "text"),
        ])
        #expect(blocks("---\nafter") == [.thematicBreak, .paragraph(text: "after")])
    }

    @Test("paragraph lines merge until a blank line")
    func paragraphs() {
        #expect(blocks("first line\n  second line\n\n\nnext paragraph   ") == [
            .paragraph(text: "first line\nsecond line"),
            .paragraph(text: "next paragraph"),
        ])
        #expect(blocks("") == [])
        #expect(blocks("\n \n\t\n") == [])
    }

    @Test("bullet and ordered list markers")
    func listMarkers() {
        #expect(blocks("- dash\n* star\n+ plus\n1. one\n2) two\n10. ten\n-not a list\n1.5 million") == [
            .listItem(ordered: false, number: nil, depth: 0, text: "dash", checkbox: nil),
            .listItem(ordered: false, number: nil, depth: 0, text: "star", checkbox: nil),
            .listItem(ordered: false, number: nil, depth: 0, text: "plus", checkbox: nil),
            .listItem(ordered: true, number: 1, depth: 0, text: "one", checkbox: nil),
            .listItem(ordered: true, number: 2, depth: 0, text: "two", checkbox: nil),
            .listItem(ordered: true, number: 10, depth: 0, text: "ten\n-not a list\n1.5 million", checkbox: nil),
        ])
        #expect(blocks("-not a list\n1.5 million") == [.paragraph(text: "-not a list\n1.5 million")])
        #expect(blocks("-") == [.listItem(ordered: false, number: nil, depth: 0, text: "", checkbox: nil)])
    }

    @Test("task items parse checkbox state")
    func taskItems() {
        #expect(blocks("- [ ] todo\n- [x] done\n* [X] Done too\n1. [ ] numbered\n- [ ]\n- [y] not a box\n- [ ]tight") == [
            .listItem(ordered: false, number: nil, depth: 0, text: "todo", checkbox: .unchecked),
            .listItem(ordered: false, number: nil, depth: 0, text: "done", checkbox: .checked),
            .listItem(ordered: false, number: nil, depth: 0, text: "Done too", checkbox: .checked),
            .listItem(ordered: true, number: 1, depth: 0, text: "numbered", checkbox: .unchecked),
            .listItem(ordered: false, number: nil, depth: 0, text: "", checkbox: .unchecked),
            .listItem(ordered: false, number: nil, depth: 0, text: "[y] not a box", checkbox: nil),
            .listItem(ordered: false, number: nil, depth: 0, text: "[ ]tight", checkbox: nil),
        ])
    }

    @Test("nesting depth follows indentation of 2 spaces, 4 spaces or tabs")
    func nestingDepth() {
        func depths(_ markdown: String) -> [Int] {
            blocks(markdown).compactMap {
                if case .listItem(_, _, let depth, _, _) = $0 { return depth }
                return nil
            }
        }
        #expect(depths("- a\n  - b\n    - c\n  - d\n- e") == [0, 1, 2, 1, 0])
        #expect(depths("- a\n    - b\n        - c\n    - d") == [0, 1, 2, 1])
        #expect(depths("- a\n\t- b\n\t\t- c\n- d") == [0, 1, 2, 0])
        #expect(depths("  - a\n  - b") == [0, 0])
        #expect(depths("1. a\n   - b\n2. c") == [0, 1, 0])
        // A paragraph ends the list, so indentation starts over.
        #expect(depths("- a\n  - b\n\nText\n\n  - c") == [0, 1, 0])
    }

    @Test("blockquotes merge consecutive and lazily continued lines")
    func blockquotes() {
        #expect(blocks("> one\n>two\n> \n>   three\nlazy\n\n> separate") == [
            .blockquote(text: "one\ntwo\n\nthree\nlazy"),
            .blockquote(text: "separate"),
        ])
    }

    @Test("fenced code keeps content verbatim with language and indentation handling")
    func codeBlocks() {
        #expect(blocks("```swift\nlet x = 1\n\n# not a heading\n```\n~~~\nplain\n~~~") == [
            .codeBlock(language: "swift", code: "let x = 1\n\n# not a heading"),
            .codeBlock(language: nil, code: "plain"),
        ])
        #expect(blocks("````md title\n```\ninner\n```\n````") == [
            .codeBlock(language: "md", code: "```\ninner\n```"),
        ])
        #expect(blocks("  ```\n  indented\n    more\n  ```") == [
            .codeBlock(language: nil, code: "indented\n  more"),
        ])
        #expect(blocks("```\nnever closed\n- item") == [
            .codeBlock(language: nil, code: "never closed\n- item"),
        ])
        #expect(blocks("``not a fence``") == [.paragraph(text: "``not a fence``")])
    }

    @Test("thematic breaks in their spellings")
    func thematicBreaks() {
        #expect(blocks("***\n\n___\n\n- - -\n\n *  *  * \n\n----------") == [
            .thematicBreak, .thematicBreak, .thematicBreak, .thematicBreak, .thematicBreak,
        ])
        #expect(blocks("--") == [.paragraph(text: "--")])
        #expect(blocks("- item\n---") == [
            .listItem(ordered: false, number: nil, depth: 0, text: "item", checkbox: nil),
            .thematicBreak,
        ])
    }

    @Test("a mixed document parses in order, CRLF included")
    func mixedDocument() {
        let markdown = "# Plan\r\n\r\nIntro text\r\n- [ ] first\r\n  - [x] nested\r\n> quote\r\n```\r\ncode\r\n```\r\n***\r\nEnd"
        #expect(blocks(markdown) == [
            .heading(level: 1, text: "Plan"),
            .paragraph(text: "Intro text"),
            .listItem(ordered: false, number: nil, depth: 0, text: "first", checkbox: .unchecked),
            .listItem(ordered: false, number: nil, depth: 1, text: "nested", checkbox: .checked),
            .blockquote(text: "quote"),
            .codeBlock(language: nil, code: "code"),
            .thematicBreak,
            .paragraph(text: "End"),
        ])
    }
}

@Suite("MarkdownStructure derived values")
struct MarkdownDerivedTests {
    @Test("outline lists headings with inline syntax removed")
    func outline() {
        let structure = MarkdownStructure(parsing: "# **Bold** title\ntext\n## [Link](https://x.y) `code`\nSetext\n---")
        #expect(structure.outline == [
            MarkdownHeading(level: 1, text: "Bold title", blockIndex: 0),
            MarkdownHeading(level: 2, text: "Link code", blockIndex: 2),
            MarkdownHeading(level: 2, text: "Setext", blockIndex: 3),
        ])
    }

    @Test("plain text strips block and inline syntax")
    func plainText() {
        let markdown = """
            # Weekly *review*

            - [x] Ship **the** [release](https://example.com)
            1. Read ![diagram](d.png)
            > Quote with `code`

            ```
            let raw = "**kept**"
            ```
            ---
            See [[Plan|the plan]] and [[Roadmap]].
            """
        #expect(MarkdownStructure.plainText(markdown) == """
            Weekly review
            Ship the release
            Read diagram
            Quote with code
            let raw = "**kept**"
            See the plan and Roadmap.
            """)
    }

    @Test("word count and reading time at 220 words per minute")
    func wordsAndReadingTime() {
        func words(_ count: Int) -> String {
            Array(repeating: "word", count: count).joined(separator: " ")
        }
        #expect(MarkdownStructure(parsing: "").wordCount == 0)
        #expect(MarkdownStructure(parsing: "").readingTimeMinutes == 0)
        #expect(MarkdownStructure(parsing: "---").readingTimeMinutes == 0)
        #expect(MarkdownStructure(parsing: "# Hello, *world* — 2026!").wordCount == 3)
        #expect(MarkdownStructure(parsing: "Hi").readingTimeMinutes == 1)
        #expect(MarkdownStructure(parsing: "- - -\n...").readingTimeMinutes == 1)
        #expect(MarkdownStructure(parsing: words(220)).readingTimeMinutes == 1)
        #expect(MarkdownStructure(parsing: words(221)).readingTimeMinutes == 2)
        #expect(MarkdownStructure(parsing: words(441)).readingTimeMinutes == 3)
        #expect(MarkdownStructure.wordCount("- [ ] buy milk\n- [x] call mom") == 4)
    }

    @Test("task progress counts checked items")
    func taskProgress() {
        let progress = MarkdownStructure(parsing: "- [x] a\n- [ ] b\n- c\n* [X] d").taskProgress
        #expect(progress.checked == 2)
        #expect(progress.total == 3)
    }
}

@Suite("MarkdownStructure checkbox toggling")
struct CheckboxToggleTests {
    @Test("toggles the n-th checkbox and nothing else")
    func togglesByIndex() {
        let markdown = "- [ ] one\n- [x] two\n  - [X] three\n- plain"
        #expect(MarkdownStructure.checkboxCount(in: markdown) == 3)
        #expect(MarkdownStructure.togglingCheckbox(at: 0, in: markdown) == "- [x] one\n- [x] two\n  - [X] three\n- plain")
        #expect(MarkdownStructure.togglingCheckbox(at: 1, in: markdown) == "- [ ] one\n- [ ] two\n  - [X] three\n- plain")
        #expect(MarkdownStructure.togglingCheckbox(at: 2, in: markdown) == "- [ ] one\n- [x] two\n  - [ ] three\n- plain")
    }

    @Test("out-of-range indices return nil")
    func outOfRange() {
        #expect(MarkdownStructure.togglingCheckbox(at: 1, in: "- [ ] only") == nil)
        #expect(MarkdownStructure.togglingCheckbox(at: -1, in: "- [ ] only") == nil)
        #expect(MarkdownStructure.togglingCheckbox(at: 0, in: "no tasks") == nil)
    }

    @Test("checkboxes in code blocks are skipped and line endings are preserved")
    func skipsCodeAndKeepsLineEndings() {
        let markdown = "```\r\n- [ ] in code\r\n```\r\n- [ ] real 🙂\r\n"
        #expect(MarkdownStructure.checkboxCount(in: markdown) == 1)
        #expect(MarkdownStructure.togglingCheckbox(at: 0, in: markdown) == "```\r\n- [ ] in code\r\n```\r\n- [x] real 🙂\r\n")
    }

    @Test("toggling twice round-trips")
    func roundTrip() {
        let markdown = "Intro\n\n1. [ ] Ünïcødé task"
        let once = MarkdownStructure.togglingCheckbox(at: 0, in: markdown)
        #expect(once == "Intro\n\n1. [x] Ünïcødé task")
        #expect(once.flatMap { MarkdownStructure.togglingCheckbox(at: 0, in: $0) } == markdown)
    }
}
