import Foundation
import Testing
import LumenFoundation
import LumenKnowledge

@Suite("WikiLinkParser")
struct WikiLinkParserTests {
    let taskID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF") ?? UUID()

    @Test("title links with and without aliases, with exact ranges")
    func titleLinks() {
        let text = "See [[Project Plan]] and [[ Roadmap | the roadmap ]]."
        let links = WikiLinkParser.links(in: text)
        #expect(links.map(\.target) == [.title("Project Plan"), .title("Roadmap")])
        #expect(links.map(\.alias) == [nil, "the roadmap"])
        #expect(links.map(\.rawText) == ["[[Project Plan]]", "[[ Roadmap | the roadmap ]]"])
        #expect(links.map { String(text[$0.range]) } == links.map(\.rawText))
        #expect(links.map(\.targetText) == ["Project Plan", "Roadmap"])
    }

    @Test("kind:UUID targets are entity mentions; anything else is a title")
    func entityMentions() {
        let noteID = UUID()
        let text = "Do [[task:\(taskID.uuidString)]] per [[note:\(noteID.uuidString.lowercased())|Spec]], not [[task:not-a-uuid]] or [[Meeting: 10:30]]"
        let links = WikiLinkParser.links(in: text)
        #expect(links.count == 4)
        #expect(links[0].target == .entity(EntityReference(kind: "task", id: taskID)))
        #expect(links[1].target == .entity(EntityReference(kind: "note", id: noteID)))
        #expect(links[1].alias == "Spec")
        #expect(links[2].target == .title("task:not-a-uuid"))
        #expect(links[3].target == .title("Meeting: 10:30"))
        #expect(links[0].targetText == "task:\(taskID.uuidString)")
    }

    @Test("empty, multi-line, bracketed and escaped candidates are not links")
    func invalidLinks() {
        for text in ["[[]]", "[[   ]]", "[[ | alias]]", "[[a\nb]]", "[[a [b] c]]", "[[a]b]]", "[single]", "\\[[Escaped]]", "[[unclosed"] {
            #expect(WikiLinkParser.links(in: text).isEmpty, "\(text.debugDescription)")
        }
        let nested = WikiLinkParser.links(in: "[[[Inner]]]")
        #expect(nested.map(\.target) == [.title("Inner")])
    }

    @Test("links and hashtags inside inline code and fenced blocks are ignored")
    func codeIsIgnored() {
        let text = """
            Text `[[Inline]] #inline` and ``a ` [[Double]]`` here
            ```swift
            [[Fenced]] #fenced
            ```
            ~~~~
            [[Tilde]] #tilde
            ~~~
            still fenced #nope
            ~~~~
            [[Real]] #real
            """
        #expect(WikiLinkParser.links(in: text).map(\.target) == [.title("Real")])
        #expect(WikiLinkParser.hashtags(in: text).map(\.tag) == ["real"])
    }

    @Test("an unclosed fence hides the rest of the document")
    func unclosedFence() {
        let parsed = WikiLinkParser.parse("[[Before]] #before\n```\n[[After]] #after")
        #expect(parsed.links.map(\.target) == [.title("Before")])
        #expect(parsed.hashtags.map(\.tag) == ["before"])
    }

    @Test("hashtags: letters, digits, dash and underscore after a boundary")
    func hashtags() {
        let text = "Ideas for #work and #Deep-Work_2, (#paren) \"#quoted\" *#bold* #café #日本語"
        let tags = WikiLinkParser.hashtags(in: text)
        #expect(tags.map(\.tag) == ["work", "Deep-Work_2", "paren", "quoted", "bold", "café", "日本語"])
        #expect(tags.map(\.normalized) == ["work", "deep-work_2", "paren", "quoted", "bold", "café", "日本語"])
        #expect(tags.map { String(text[$0.range]) } == tags.map { "#" + $0.tag })
    }

    @Test("headings, numbers, fragments, entities and mid-word hashes are not hashtags")
    func notHashtags() {
        let text = """
            # Heading
            ## Sub heading
            #tag at line start
            C# and issue #42 and a.com/#frag and &#123; [jump](#anchor) mid#word ##double \\#escaped
            """
        #expect(WikiLinkParser.hashtags(in: text).map(\.tag) == ["tag"])
    }

    @Test("hashtags inside link text are skipped with the link")
    func hashtagsInsideLinks() {
        let parsed = WikiLinkParser.parse("[[Note #1 #tag]] then #after")
        #expect(parsed.links.map(\.target) == [.title("Note #1 #tag")])
        #expect(parsed.hashtags.map(\.tag) == ["after"])
    }

    @Test("results are in source order and normalized tags are deduplicated")
    func ordering() {
        let parsed = WikiLinkParser.parse("[[B]] #Two [[A]]\n#one #two [[C]]\r\n#TWO")
        #expect(parsed.links.map(\.targetText) == ["B", "A", "C"])
        #expect(parsed.hashtags.map(\.tag) == ["Two", "one", "two", "TWO"])
        #expect(parsed.normalizedTags == ["two", "one"])
    }
}
