import Foundation
import Testing
import LumenKnowledge

@Suite("NoteTagging")
struct NoteTaggingTests {
    @Test("tags combine explicit tags and body hashtags, normalized and deduplicated")
    func combine() {
        let tags = NoteTagging.tags(explicit: ["Work", " Deep Work "], body: "Plan #work and #Ideas `#code`")
        #expect(tags == ["work", "deep-work", "ideas"])
    }

    @Test("removing a hashtag removes its derived tag but keeps explicit tags")
    func retag() {
        let current = NoteTagging.tags(explicit: ["pinned-topic"], body: "About #alpha and #beta")
        #expect(current == ["pinned-topic", "alpha", "beta"])
        #expect(NoteTagging.retag(current, previousBody: "About #alpha and #beta", newBody: "About #beta and #gamma") == ["pinned-topic", "beta", "gamma"])
        #expect(NoteTagging.explicitTags(current, body: "About #alpha and #beta") == ["pinned-topic"])
    }

    @Test("hashtag rewriting replaces only real hashtags of the source tags")
    func rewrite() {
        let body = "#Old idea, #older, `#old` and #old.\n```\n#old\n```"
        let rewritten = NoteTagging.rewritingHashtags(in: body, replacing: ["old"], with: "new")
        #expect(rewritten == "#new idea, #older, `#old` and #new.\n```\n#old\n```")
        #expect(NoteTagging.rewritingHashtags(in: "nothing here", replacing: ["old"], with: "new") == "nothing here")
        #expect(NoteTagging.containsHashtag(for: ["old"], in: body))
        #expect(!NoteTagging.containsHashtag(for: ["old"], in: "`#old`"))
    }

    @Test("link title keys fold case, diacritics and whitespace")
    func linkTitleKeys() {
        #expect(LinkTitle.matchingKey("  Café   Notes ") == LinkTitle.matchingKey("cafe notes"))
        #expect(LinkTitle.matchingKey("ÉTÉ") == "ete")
        #expect(LinkTitle.matchingKey("A") != LinkTitle.matchingKey("B"))
    }
}
