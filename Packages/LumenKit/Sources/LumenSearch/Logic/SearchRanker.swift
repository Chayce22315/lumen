import Foundation
import LumenFoundation

/// Final relevance: FTS5 bm25 relevance, boosted by how well the title matches, recency and the
/// source's own boost. Pure, so ranking changes are covered by tests.
public enum SearchRanker {
    public struct Candidate: Sendable, Hashable {
        public let title: String
        /// SQLite's bm25: lower (more negative) is better.
        public let bm25: Double
        public let updatedAt: Date
        public let boost: Double

        public init(title: String, bm25: Double, updatedAt: Date, boost: Double) {
            self.title = title
            self.bm25 = bm25
            self.updatedAt = updatedAt
            self.boost = boost
        }
    }

    public static let recencyHalfLifeDays = 30.0

    public static func score(_ candidate: Candidate, queryTokens: [String], queryText: String, now: Date) -> Double {
        let relevance = max(0.001, -candidate.bm25)
        let title = candidate.title.foldedForMatching
        let query = queryText.foldedForMatching.collapsingWhitespace
        let titleTokens = candidate.title.matchingTokens

        var titleBoost = 1.0
        if !query.isEmpty && title == query {
            titleBoost = 3
        } else if !query.isEmpty && title.hasPrefix(query) {
            titleBoost = 2
        } else if !queryTokens.isEmpty && queryTokens.allSatisfy({ token in titleTokens.contains { $0.hasPrefix(token) } }) {
            titleBoost = 1.5
        }

        let ageDays = max(0, now.timeIntervalSince(candidate.updatedAt) / 86_400)
        let recency = 1 + 0.5 * pow(0.5, ageDays / recencyHalfLifeDays)
        return relevance * titleBoost * recency * candidate.boost
    }
}
