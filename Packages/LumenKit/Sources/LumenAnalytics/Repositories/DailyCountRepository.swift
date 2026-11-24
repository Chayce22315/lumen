import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// SQL for `analytics_daily_counts`, the per-day aggregate that outlives raw-event retention.
enum DailyCountRepository {
    /// Adds `amount` to the count of (`day`, `name`, `actor`), creating the row if needed.
    static func increment(day: CalendarDate, name: EventName, actor: EventActor, by amount: Int = 1, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO analytics_daily_counts (day, name, actor, count) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, name, actor) DO UPDATE SET count = analytics_daily_counts.count + excluded.count
            """,
            [day, name.rawValue, actor.rawValue, max(0, amount)]
        )
    }

    /// Counts within `range`, optionally limited to `names` and `actors` (`nil` means all).
    static func counts(names: Set<EventName>?, in range: DayRange, actors: Set<EventActor>?, in db: DatabaseConnection) throws -> [DailyCount] {
        try db.query(
            """
            SELECT day, name, actor, count FROM analytics_daily_counts
            WHERE day BETWEEN ?1 AND ?2
              AND (?3 IS NULL OR name IN (SELECT value FROM json_each(?3)))
              AND (?4 IS NULL OR actor IN (SELECT value FROM json_each(?4)))
            ORDER BY day, name, actor
            """,
            [range.start, range.end, try FilterArgument.names(names), try FilterArgument.actors(actors)]
        ).map(DailyCount.init(row:))
    }

    /// Every day up to and including `day` on which any of `names` happened.
    static func activeDays(names: Set<EventName>, through day: CalendarDate, in db: DatabaseConnection) throws -> Set<CalendarDate> {
        guard !names.isEmpty else { return [] }
        let rows = try db.query(
            """
            SELECT DISTINCT day FROM analytics_daily_counts
            WHERE day <= ?1 AND count > 0 AND name IN (SELECT value FROM json_each(?2))
            """,
            [day, try FilterArgument.names(names)]
        )
        return Set(try rows.map { try $0.get("day", as: CalendarDate.self) })
    }

    /// The earliest day with any recorded event, or `nil` when nothing was recorded.
    static func firstDay(in db: DatabaseConnection) throws -> CalendarDate? {
        let first = try db.scalar("SELECT min(day) FROM analytics_daily_counts", as: CalendarDate?.self)
        return first ?? nil
    }

    static func deleteAll(in db: DatabaseConnection) throws -> Int {
        try db.execute("DELETE FROM analytics_daily_counts")
        return db.changes
    }
}
