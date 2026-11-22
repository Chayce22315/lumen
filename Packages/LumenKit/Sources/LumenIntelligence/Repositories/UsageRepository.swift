import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for device-local usage records (no change records: usage is not synchronized).
public enum UsageRepository {
    /// Inserts a record; `day` is its local calendar day, fixed at record time.
    public static func insert(_ record: UsageRecord, day: CalendarDate, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO intelligence_usage
                (provider_id, model_id, conversation_id, message_id, input_tokens, output_tokens,
                 cache_creation_tokens, cache_read_tokens, recorded_at, day)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                record.providerID, record.modelID, record.conversationID, record.messageID,
                record.usage.input, record.usage.output, record.usage.cacheCreation, record.usage.cacheRead,
                record.recordedAt, day,
            ]
        )
    }

    /// Totals of records with `start <= recorded_at < end`, grouped and ordered by the bucket key.
    public static func totals(from start: Date, to end: Date, groupedBy grouping: UsageGrouping, in db: DatabaseConnection) throws -> [UsageTotal] {
        let key: String
        switch grouping {
        case .day: key = "day"
        case .model: key = "provider_id, model_id"
        case .provider: key = "provider_id"
        }
        let rows = try db.query(
            """
            SELECT \(key),
                   sum(input_tokens) AS input, sum(output_tokens) AS output,
                   sum(cache_creation_tokens) AS cache_creation, sum(cache_read_tokens) AS cache_read,
                   count(*) AS completions
            FROM intelligence_usage
            WHERE recorded_at >= ? AND recorded_at < ?
            GROUP BY \(key)
            ORDER BY \(key)
            """,
            [start, end]
        )
        return try rows.map { row in
            let usage = TokenUsage(
                input: try row.get("input"),
                output: try row.get("output"),
                cacheCreation: try row.get("cache_creation"),
                cacheRead: try row.get("cache_read")
            )
            let completions: Int = try row.get("completions")
            switch grouping {
            case .day:
                return UsageTotal(day: try row.get("day"), usage: usage, completions: completions)
            case .model:
                return UsageTotal(providerID: try row.get("provider_id"), modelID: try row.get("model_id"), usage: usage, completions: completions)
            case .provider:
                return UsageTotal(providerID: try row.get("provider_id"), usage: usage, completions: completions)
            }
        }
    }

    /// One total over the range (zero when there are no records).
    public static func total(from start: Date, to end: Date, in db: DatabaseConnection) throws -> UsageTotal {
        guard let row = try db.queryFirst(
            """
            SELECT coalesce(sum(input_tokens), 0) AS input, coalesce(sum(output_tokens), 0) AS output,
                   coalesce(sum(cache_creation_tokens), 0) AS cache_creation,
                   coalesce(sum(cache_read_tokens), 0) AS cache_read, count(*) AS completions
            FROM intelligence_usage WHERE recorded_at >= ? AND recorded_at < ?
            """,
            [start, end]
        ) else {
            return UsageTotal(usage: .zero, completions: 0)
        }
        return UsageTotal(
            usage: TokenUsage(
                input: try row.get("input"),
                output: try row.get("output"),
                cacheCreation: try row.get("cache_creation"),
                cacheRead: try row.get("cache_read")
            ),
            completions: try row.get("completions")
        )
    }

    /// Removes records older than `cutoff`.
    public static func purge(recordedBefore cutoff: Date, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM intelligence_usage WHERE recorded_at < ?", [cutoff])
    }
}
