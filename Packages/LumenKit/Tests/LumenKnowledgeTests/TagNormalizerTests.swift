import Foundation
import Testing
import LumenFoundation
import LumenKnowledge

@Suite("TagNormalizer")
struct TagNormalizerTests {
    @Test("trims, strips leading hashes, lowercases and joins words with dashes")
    func normalization() {
        #expect(TagNormalizer.normalize("  #Work ") == "work")
        #expect(TagNormalizer.normalize("##Deep  Work") == "deep-work")
        #expect(TagNormalizer.normalize("Multi\tword\ntag") == "multi-word-tag")
        #expect(TagNormalizer.normalize("# Spaced") == "spaced")
        #expect(TagNormalizer.normalize("Café") == "café")
        #expect(TagNormalizer.normalize("C++") == "c++")
        #expect(TagNormalizer.normalize("a#b") == "a#b")
    }

    @Test("rejects input that normalizes to nothing")
    func rejectsEmpty() {
        for raw in ["", "   ", "#", "###", "# \n #"] {
            #expect(TagNormalizer.normalize(raw) == nil, "\(raw.debugDescription)")
        }
        #expect(throws: ValidationError.self) { try TagNormalizer.validated("  # ") }
        #expect(throws: Never.self) { try TagNormalizer.validated("#ok") }
    }

    @Test("deduplicates while keeping first occurrences in order")
    func deduplication() {
        #expect(TagNormalizer.normalize(["B", "a", "#b", "A ", "", "c"]) == ["b", "a", "c"])
        #expect(TagNormalizer.normalize([String]()) == [])
    }

    @Test("caps length at 64 characters without a dangling dash")
    func maximumLength() {
        let long = String(repeating: "x", count: 100)
        #expect(TagNormalizer.normalize(long) == String(repeating: "x", count: 64))
        let dashAtCut = String(repeating: "a", count: 63) + " b"
        #expect(TagNormalizer.normalize(dashAtCut) == String(repeating: "a", count: 63))
        let emoji = String(repeating: "🙂", count: 70)
        #expect(TagNormalizer.normalize(emoji)?.count == 64)
    }

    @Test("hashtag compatibility requires tag characters and a letter")
    func hashtagCompatibility() {
        #expect(TagNormalizer.isHashtagCompatible("deep-work"))
        #expect(TagNormalizer.isHashtagCompatible("v1_2"))
        #expect(TagNormalizer.isHashtagCompatible("日本"))
        #expect(!TagNormalizer.isHashtagCompatible("c++"))
        #expect(!TagNormalizer.isHashtagCompatible("2024"))
        #expect(!TagNormalizer.isHashtagCompatible("two words"))
        #expect(!TagNormalizer.isHashtagCompatible(""))
    }
}
