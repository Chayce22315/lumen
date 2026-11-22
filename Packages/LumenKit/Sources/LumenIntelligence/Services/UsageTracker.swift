import Foundation
import LumenFoundation
import LumenPersistence

/// Token usage per completion and totals over date ranges. Device-local.
public final class UsageTracker: Sendable {
    private let database: Database
    private let calendar: Calendar
    private let logger: Logger

    public init(database: Database, calendar: Calendar, logger: Logger) {
        self.database = database
        self.calendar = calendar
        self.logger = logger
    }

    public func record(_ record: UsageRecord) async throws {
        let day = CalendarDate(record.recordedAt, calendar: calendar)
        try await database.write { db in try UsageRepository.insert(record, day: day, in: db) }
    }

    /// The local calendar day a record made at `date` is bucketed under.
    func day(of date: Date) -> CalendarDate {
        CalendarDate(date, calendar: calendar)
    }

    /// Totals for records in `interval` (start inclusive, end exclusive), one per bucket.
    public func totals(in interval: DateInterval, groupedBy grouping: UsageGrouping) async throws -> [UsageTotal] {
        try await database.read { db in
            try UsageRepository.totals(from: interval.start, to: interval.end, groupedBy: grouping, in: db)
        }
    }

    /// Totals per local day for the calendar days `from...through`.
    public func dailyTotals(from first: CalendarDate, through last: CalendarDate) async throws -> [UsageTotal] {
        let interval = DateInterval(start: first.startDate(in: calendar), end: last.adding(days: 1).startDate(in: calendar))
        return try await totals(in: interval, groupedBy: .day)
    }

    /// One total for `interval`.
    public func total(in interval: DateInterval) async throws -> UsageTotal {
        try await database.read { db in try UsageRepository.total(from: interval.start, to: interval.end, in: db) }
    }

    /// Deletes records older than `cutoff`.
    public func purge(recordedBefore cutoff: Date) async throws {
        try await database.write { db in try UsageRepository.purge(recordedBefore: cutoff, in: db) }
        logger.info("Usage records purged")
    }
}
