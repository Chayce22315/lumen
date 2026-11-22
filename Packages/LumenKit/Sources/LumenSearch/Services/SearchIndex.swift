import Foundation
import LumenFoundation
import LumenPersistence

/// The global full-text index over every searchable entity.
public final class SearchIndex: Sendable {
    public static let schema = SearchSchema.schema

    /// Column weights for bm25: title matters most, then tags, then body.
    static let bm25Expression = "bm25(search_fts, 10.0, 1.0, 4.0)"

    private let database: Database
    private let timeSource: any TimeSource

    public init(database: Database, timeSource: any TimeSource) {
        self.database = database
        self.timeSource = timeSource
    }

    public func upsert(_ documents: [SearchDocument]) async throws {
        guard !documents.isEmpty else { return }
        try await database.write { db in
            for document in documents {
                try Self.upsert(document, in: db)
            }
        }
    }

    public func upsert(_ document: SearchDocument) async throws {
        try await upsert([document])
    }

    public func remove(_ reference: EntityReference) async throws {
        try await database.write { db in try Self.remove(reference, in: db) }
    }

    /// Replaces every document of `kind` with `documents` in one transaction.
    public func replaceAll(of kind: EntityKind, with documents: [SearchDocument]) async throws {
        try await database.write { db in
            let rows = try db.query("SELECT fts_rowid FROM search_entries WHERE entity_kind = ?", [kind])
            for row in rows {
                try db.execute("DELETE FROM search_fts WHERE rowid = ?", [try row.get("fts_rowid", as: Int64.self)])
            }
            try db.execute("DELETE FROM search_entries WHERE entity_kind = ?", [kind])
            for document in documents where document.reference.kind == kind {
                try Self.upsert(document, in: db)
            }
        }
    }

    public func documentCount(kind: EntityKind? = nil) async throws -> Int {
        try await database.read { db in
            if let kind {
                return try db.scalar("SELECT count(*) FROM search_entries WHERE entity_kind = ?", [kind]) ?? 0
            }
            return try db.scalar("SELECT count(*) FROM search_entries") ?? 0
        }
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        guard let expression = FTSQueryBuilder.matchExpression(for: query.text) else { return [] }
        let tokens = FTSQueryBuilder.tokens(for: query.text)
        let candidateLimit = query.limit * 4
        var sql = """
            SELECT e.entity_kind, e.entity_id, e.title, e.subtitle, e.tags, e.updated_at, e.boost,
                   search_fts.body AS body, \(Self.bm25Expression) AS rank
            FROM search_fts JOIN search_entries e ON e.fts_rowid = search_fts.rowid
            WHERE search_fts MATCH ?
            """
        var arguments: [any DatabaseValueConvertible] = [expression]
        if let kinds = query.kinds {
            guard !kinds.isEmpty else { return [] }
            sql += " AND e.entity_kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"
            let sortedKinds: [EntityKind] = kinds.sorted()
            arguments.append(contentsOf: sortedKinds as [any DatabaseValueConvertible])
        }
        sql += " ORDER BY rank LIMIT ?"
        arguments.append(candidateLimit)
        let finalSQL = sql
        let finalArguments = arguments
        let rows = try await database.read { db in try db.query(finalSQL, finalArguments) }

        let now = timeSource.now()
        var results: [SearchResult] = []
        for row in rows {
            let tags: [String] = try row.json("tags")
            guard query.tags.isSubset(of: Set(tags)) else { continue }
            let title: String = try row.get("title")
            let body: String = try row.get("body")
            let updatedAt: Date = try row.get("updated_at")
            let score = SearchRanker.score(
                SearchRanker.Candidate(title: title, bm25: try row.get("rank"), updatedAt: updatedAt, boost: try row.get("boost")),
                queryTokens: tokens,
                queryText: query.text,
                now: now
            )
            results.append(SearchResult(
                reference: EntityReference(kind: try row.get("entity_kind"), id: try row.get("entity_id", as: UUID.self)),
                title: title,
                titleHighlights: SnippetBuilder.highlights(in: title, tokens: tokens),
                subtitle: try row.get("subtitle"),
                snippet: SnippetBuilder.snippet(for: body, tokens: tokens),
                tags: tags,
                updatedAt: updatedAt,
                score: score
            ))
        }
        return Array(results.sorted { ($0.score, $1.reference.uri) > ($1.score, $0.reference.uri) }.prefix(query.limit))
    }

    // MARK: - Row helpers

    static func upsert(_ document: SearchDocument, in db: DatabaseConnection) throws {
        try remove(document.reference, in: db)
        let body = String(document.body.prefix(SearchDocument.maximumBodyLength))
        try db.execute(
            "INSERT INTO search_fts (title, body, tags) VALUES (?, ?, ?)",
            [document.title, body, document.tags.joined(separator: " ")]
        )
        let rowID = db.lastInsertedRowID
        try db.execute(
            """
            INSERT INTO search_entries (entity_kind, entity_id, fts_rowid, title, subtitle, tags, updated_at, boost)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [document.reference.kind, document.reference.id, rowID, document.title, document.subtitle, JSONColumn(document.tags), document.updatedAt, document.boost]
        )
    }

    static func remove(_ reference: EntityReference, in db: DatabaseConnection) throws {
        if let rowID: Int64 = try db.scalar(
            "SELECT fts_rowid FROM search_entries WHERE entity_kind = ? AND entity_id = ?",
            [reference.kind, reference.id]
        ) {
            try db.execute("DELETE FROM search_fts WHERE rowid = ?", [rowID])
            try db.execute("DELETE FROM search_entries WHERE entity_kind = ? AND entity_id = ?", [reference.kind, reference.id])
        }
    }
}
