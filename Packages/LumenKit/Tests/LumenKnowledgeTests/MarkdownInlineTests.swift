import Foundation
import Testing
import LumenKnowledge

@Suite("Markdown inline plain text")
struct MarkdownInlineTests {
    func plain(_ text: String) -> String {
        MarkdownStructure.plainText(text)
    }

    @Test("matched emphasis delimiters are removed")
    func emphasis() {
        #expect(plain("**bold** and *em* and __strong__ and _em_ and ~~gone~~ and ***both***") == "bold and em and strong and em and gone and both")
        #expect(plain("**nested *inner* text**") == "nested inner text")
    }

    @Test("literal stars, underscores and unmatched runs survive")
    func literals() {
        #expect(plain("use snake_case_names here") == "use snake_case_names here")
        #expect(plain("2 * 3 * 4 = 24") == "2 * 3 * 4 = 24")
        #expect(plain("**open without close") == "**open without close")
        #expect(plain("~5 minutes") == "~5 minutes")
    }

    @Test("links, images, autolinks and code keep their visible text")
    func links() {
        #expect(plain("[Lumen](https://lumen.app/(x)) and ![logo](a.png)") == "Lumen and logo")
        #expect(plain("[**bold link**](u)") == "bold link")
        #expect(plain("Visit <https://example.com> or <me@example.com>; <not a link>") == "Visit https://example.com or me@example.com; <not a link>")
        #expect(plain("Run `let x = *1*` now; `` a ` b ``") == "Run let x = *1* now; a ` b")
        #expect(plain("[not a link] and [also](") == "[not a link] and [also](")
    }

    @Test("wiki links show alias or title; bare entity mentions are dropped")
    func wikiLinks() {
        let id = UUID().uuidString
        #expect(plain("See [[Plan|the plan]], [[Roadmap]] and [[task:\(id)]] or [[task:\(id)|this task]].") == "See the plan, Roadmap and  or this task.")
    }

    @Test("backslash escapes produce the literal character")
    func escapes() {
        #expect(plain(#"\*not em\* and \_x\_ and \[[no link]] and a\b"#) == #"*not em* and _x_ and [[no link]] and a\b"#)
    }
}
