import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// SQL for `analytics_daily_totals`: per-day sums of `AnalyticsMeasure`s, kept like daily counts.
enum DailyTotalRepository {
    /// Adds `amount` to the total of (`day`, `measure`, `actor`), creating the row if needed.
    static func add(_ amount: Double, day: CalendarDate, measure: String, actor: EventActor, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO analytics_daily_totals (day, measure, actor, total) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, measure, actor) DO UPDATE SET total = analytics_daily_totals.total + excluded.total
            """,
            [day, measure, actor.rawValue, max(0, amount)]
        )
    }

    /// The measure's total per day within `range`, summed over actors. Days without a total are absent.
    static func totals(measure: String, in range: DayRange, in db: DatabaseConnection) throws -> [CalendarDate: Double] {
        let rows = try db.query(
            """
            SELECT day, sum(total) AS total FROM analytics_daily_totals
            WHERE measure = ? AND day BETWEEN ? AND ?
            GROUP BY day ORDER BY day
            """,
            [measure, range.start, range.end]
        )
        var result: [CalendarDate: Double] = [:]
        for row in rows {
            result[try row.get("day", as: CalendarDate.self)] = try row.get("total", as: Double.self)
        }
        return result
    }

    static func deleteAll(in db: DatabaseConnection) throws -> Int {
        try db.execute("DELETE FROM analytics_daily_totals")
        return db.changes
    }
}
