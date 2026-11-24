import Foundation
import Testing
import LumenFoundation
import LumenSearch

@Suite("Search logic")
struct SearchLogicTests {
    @Test("FTS expressions quote and prefix every token and never pass syntax through")
    func ftsExpression() {
        #expect(FTSQueryBuilder.matchExpression(for: "Réunion budget") == "\"reunion\"* \"budget\"*")
        #expect(FTSQueryBuilder.matchExpression(for: "a OR b NOT \"c\"") == "\"a\"* \"or\"* \"b\"* \"not\"* \"c\"*")
        #expect(FTSQueryBuilder.matchExpression(for: "*** ( ) :") == nil)
        #expect(FTSQueryBuilder.tokens(for: String(repeating: "w ", count: 40)).count == FTSQueryBuilder.maximumTokens)
    }

    @Test("fuzzy matching requires order and rewards word starts and contiguity")
    func fuzzy() throws {
        #expect(FuzzyMatcher.match("nt", in: "New task") != nil)
        #expect(FuzzyMatcher.match("tn", in: "New task") == nil)
        let wordStarts = try #require(FuzzyMatcher.match("nt", in: "New task"))
        let scattered = try #require(FuzzyMatcher.match("nt", in: "Plant seeds"))
        #expect(wordStarts.score > scattered.score)
        let contiguous = try #require(FuzzyMatcher.match("set", in: "Settings"))
        let spread = try #require(FuzzyMatcher.match("set", in: "Save entry text"))
        #expect(contiguous.score > spread.score)
        #expect(FuzzyMatcher.highlights(for: [0, 1, 2, 5]) == [HighlightRange(offset: 0, length: 3), HighlightRange(offset: 5, length: 1)])
        #expect(FuzzyMatcher.match("cafe", in: "Café plans")?.indices == [0, 1, 2, 3])
    }

    @Test("snippets center on the first match, mark every token and add ellipses")
    func snippets() throws {
        let body = String(repeating: "lorem ipsum ", count: 30) + "the quarterly Budget review is on Friday " + String(repeating: "dolor sit ", count: 30)
        let snippet = try #require(SnippetBuilder.snippet(for: body, tokens: ["budget", "friday"]))
        #expect(snippet.text.hasPrefix("…"))
        #expect(snippet.text.hasSuffix("…"))
        let marked = snippet.highlights.map { range -> String in
            let characters = Array(snippet.text)
            return String(characters[range.offset..<(range.offset + range.length)])
        }
        #expect(marked == ["Budget", "Friday"])
        #expect(SnippetBuilder.snippet(for: "nothing here", tokens: ["budget"]) == nil)
        #expect(SnippetBuilder.highlights(in: "Crème brûlée", tokens: ["creme", "brulee"]) == [HighlightRange(offset: 0, length: 5), HighlightRange(offset: 6, length: 6)])
    }

    @Test("ranking prefers exact titles, then prefixes, then recency")
    func ranking() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func score(_ title: String, bm25: Double = -1, ageDays: Double = 0, boost: Double = 1) -> Double {
            SearchRanker.score(
                SearchRanker.Candidate(title: title, bm25: bm25, updatedAt: now.addingTimeInterval(-ageDays * 86_400), boost: boost),
                queryTokens: ["budget"], queryText: "budget", now: now)
        }
        #expect(score("Budget") > score("Budget 2027"))
        #expect(score("Budget 2027") > score("Quarterly budget"))
        #expect(score("Quarterly budget") > score("Unrelated title"))
        #expect(score("Notes", ageDays: 0) > score("Notes", ageDays: 90))
        #expect(score("Notes", boost: 0.5) < score("Notes"))
    }
}
