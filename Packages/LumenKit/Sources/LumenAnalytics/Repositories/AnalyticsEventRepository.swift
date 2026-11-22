import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// SQL for `analytics_events`, the raw event log. Analytics rows are private to the device, so
/// writes here never record change-log entries.
enum AnalyticsEventRepository {
    /// Inserts `record`. Returns `false` (and changes nothing) when an event with the same id was
    /// already recorded, which makes recording idempotent.
    static func insert(_ record: AnalyticsEventRecord, in db: DatabaseConnection) throws -> Bool {
        try db.execute(
            """
            INSERT INTO analytics_events
                (id, name, entity_kind, entity_id, actor, occurred_at, day, hour, attributes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                record.id, record.name.rawValue, record.entityKind, record.entityID, record.actor.rawValue,
                record.occurredAt, record.day, record.hour, JSONColumn(record.attributes),
            ]
        )
        return db.changes == 1
    }

    /// The most recent events, newest first, optionally limited to `names`.
    static func recent(limit: Int, names: Set<EventName>?, in db: DatabaseConnection) throws -> [AnalyticsEventRecord] {
        try db.query(
            """
            SELECT * FROM analytics_events
            WHERE (?1 IS NULL OR name IN (SELECT value FROM json_each(?1)))
            ORDER BY occurred_at DESC, id DESC
            LIMIT ?2
            """,
            [try FilterArgument.names(names), max(1, limit)]
        ).map(AnalyticsEventRecord.init(row:))
    }

    /// Events per name and hour of day within `range`.
    static func hourlyCounts(names: Set<EventName>?, in range: DayRange, in db: DatabaseConnection) throws -> [HourlyCount] {
        try db.query(
            """
            SELECT name, hour, count(*) AS count FROM analytics_events
            WHERE day BETWEEN ?1 AND ?2
              AND (?3 IS NULL OR name IN (SELECT value FROM json_each(?3)))
            GROUP BY name, hour
            ORDER BY name, hour
            """,
            [range.start, range.end, try FilterArgument.names(names)]
        ).map(HourlyCount.init(row:))
    }

    /// Deletes events recorded on days before `day`; returns how many were deleted.
    static func deleteEvents(before day: CalendarDate, in db: DatabaseConnection) throws -> Int {
        try db.execute("DELETE FROM analytics_events WHERE day < ?", [day])
        return db.changes
    }

    static func deleteAll(in db: DatabaseConnection) throws -> Int {
        try db.execute("DELETE FROM analytics_events")
        return db.changes
    }

    static func count(in db: DatabaseConnection) throws -> Int {
        try db.scalar("SELECT count(*) FROM analytics_events") ?? 0
    }
}
