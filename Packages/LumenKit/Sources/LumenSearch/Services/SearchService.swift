import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Everything the command palette shows for one query.
public struct PaletteResults: Sendable, Hashable {
    public let query: String
    public let commands: [RankedCommand]
    public let results: [SearchResult]
    /// Earlier queries that start with the current text (or the most recent ones when empty).
    public let history: [SearchHistoryEntry]

    public var isEmpty: Bool { commands.isEmpty && results.isEmpty && history.isEmpty }
}

/// Universal search: content results, commands and search history behind one API.
public final class SearchService: Sendable {
    public static let historyLimit = 50

    private let index: SearchIndex
    private let commands: CommandRegistry
    private let database: Database
    private let timeSource: any TimeSource

    public init(index: SearchIndex, commands: CommandRegistry, database: Database, timeSource: any TimeSource) {
        self.index = index
        self.commands = commands
        self.database = database
        self.timeSource = timeSource
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        try await index.search(query)
    }

    /// Commands, content and history for the palette. Does not record history (call `recordSearch`
    /// when the user commits to a query or opens a result).
    public func palette(_ text: String, kinds: Set<EntityKind>? = nil, resultLimit: Int = 20, commandLimit: Int = 6) async throws -> PaletteResults {
        let trimmed = text.collapsingWhitespace
        async let results = trimmed.isEmpty ? [] : index.search(SearchQuery(text: trimmed, kinds: kinds, limit: resultLimit))
        let ranked = commands.search(trimmed, limit: commandLimit)
        let history = try await history(matching: trimmed, limit: trimmed.isEmpty ? 6 : 3)
        return PaletteResults(query: trimmed, commands: ranked, results: try await results, history: history)
    }

    // MARK: - History

    public func recordSearch(_ text: String) async throws {
        guard let query = text.collapsingWhitespace.nonBlank else { return }
        let normalized = query.foldedForMatching
        let now = timeSource.now()
        let limit = Self.historyLimit
        try await database.write { db in
            try db.execute(
                """
                INSERT INTO search_history (normalized, query, last_used, use_count) VALUES (?, ?, ?, 1)
                ON CONFLICT(normalized) DO UPDATE SET query = excluded.query, last_used = excluded.last_used, use_count = use_count + 1
                """,
                [normalized, query, now]
            )
            try db.execute(
                "DELETE FROM search_history WHERE normalized NOT IN (SELECT normalized FROM search_history ORDER BY last_used DESC LIMIT ?)",
                [limit]
            )
        }
    }

    public func history(matching prefix: String = "", limit: Int = 10) async throws -> [SearchHistoryEntry] {
        let folded = prefix.foldedForMatching
        let rows = try await database.read { db in
            try db.query("SELECT * FROM search_history ORDER BY last_used DESC LIMIT ?", [Self.historyLimit])
        }
        let entries = try rows.map { row in
            SearchHistoryEntry(query: try row.get("query"), lastUsed: try row.get("last_used"), useCount: try row.get("use_count"))
        }
        let filtered = folded.isEmpty ? entries : entries.filter { $0.query.foldedForMatching.hasPrefix(folded) && $0.query.foldedForMatching != folded }
        return Array(filtered.prefix(max(0, limit)))
    }

    public func removeHistoryEntry(_ query: String) async throws {
        let normalized = query.collapsingWhitespace.foldedForMatching
        try await database.write { db in try db.execute("DELETE FROM search_history WHERE normalized = ?", [normalized]) }
    }

    public func clearHistory() async throws {
        try await database.write { db in try db.execute("DELETE FROM search_history") }
    }
}
