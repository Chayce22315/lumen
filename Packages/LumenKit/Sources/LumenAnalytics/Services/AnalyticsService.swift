import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Lumen's analytics query API: counts, chart-ready series, comparisons, distributions, usage
/// summaries, the activity feed, insights and reports — plus the user's controls over collection
/// and erasure.
///
/// Analytics data is device-local and private. It is never written to the change log, never
/// synchronized and never sent anywhere. Recording is done by `AnalyticsCollector`.
///
/// Counts, series, comparisons, weekday distributions, streaks and reports read the daily
/// counts, which are kept until erased. Hour-of-day distributions and recent events read raw
/// events and therefore cover the collector's retention window only.
public final class AnalyticsService: Sendable {
    public static let schema = AnalyticsSchema.schema

    let database: Database
    private let settings: SettingsStore
    private let events: EventBus
    let timeSource: any TimeSource
    let calendar: Calendar
    private let logger: Logger
    let generator: InsightGenerator

    public init(
        database: Database,
        settings: SettingsStore,
        events: EventBus,
        timeSource: any TimeSource,
        calendar: Calendar,
        logger: Logger,
        thresholds: InsightThresholds = .standard
    ) {
        self.database = database
        self.settings = settings
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
        self.generator = InsightGenerator(thresholds: thresholds)
    }

    /// Today in the service's calendar.
    public func today() -> CalendarDate {
        CalendarDate(timeSource.now(), calendar: calendar)
    }

    // MARK: - Collection controls

    public func isCollectionEnabled() async -> Bool {
        await settings.value(AnalyticsSettings.collectionEnabled)
    }

    /// Turns recording on or off. Turning it off keeps existing data; use `eraseAllData()` to remove it.
    public func setCollectionEnabled(_ enabled: Bool) async throws {
        try await settings.set(enabled, for: AnalyticsSettings.collectionEnabled)
        logger.notice(enabled ? "Analytics collection enabled" : "Analytics collection disabled")
    }

    /// Deletes every recorded event and every daily count, then publishes
    /// `AnalyticsEvents.dataErased`. Collection continues according to the setting.
    public func eraseAllData(context: ActionContext = .user) async throws {
        let deleted = try await database.write { db in
            let events = try AnalyticsEventRepository.deleteAll(in: db)
            let counts = try DailyCountRepository.deleteAll(in: db)
            return ErasedRows(events: events, dailyCounts: counts)
        }
        logger.notice("Erased all analytics data", metadata: [
            "events": String(deleted.events),
            "dailyCounts": String(deleted.dailyCounts),
        ])
        events.publish(context.event(AnalyticsEvents.dataErased, at: timeSource.now()))
    }

    // MARK: - Counts and series

    /// How often each of `names` happened in `range`, optionally only for `actors`. Every
    /// requested name is present in the result, with 0 when it never happened.
    public func counts(of names: Set<EventName>, in range: DayRange, actors: Set<EventActor>? = nil) async throws -> [EventName: Int] {
        let rows = try await dailyCounts(names: names, in: range, actors: actors)
        var result = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        for row in rows {
            result[row.name, default: 0] += row.count
        }
        return result
    }

    /// How often any of `names` happened in `range`, optionally only for `actors`.
    public func totalCount(of names: Set<EventName>, in range: DayRange, actors: Set<EventActor>? = nil) async throws -> Int {
        try await dailyCounts(names: names, in: range, actors: actors).total(names: nil)
    }

    /// Occurrences of `names` per day of `range`, zero-filled.
    public func dailySeries(of names: Set<EventName>, in range: DayRange, actors: Set<EventActor>? = nil) async throws -> TimeSeries {
        let rows = try await dailyCounts(names: names, in: range, actors: actors)
        return SeriesBuilder.daily(rows.valuesByDay(names: nil), in: range)
    }

    /// Occurrences of `names` per calendar week over `range` (see `SeriesBuilder.weekly` for
    /// partial weeks at the edges).
    public func weeklySeries(of names: Set<EventName>, in range: DayRange, actors: Set<EventActor>? = nil) async throws -> TimeSeries {
        SeriesBuilder.weekly(try await dailySeries(of: names, in: range, actors: actors), calendar: calendar)
    }

    /// Occurrences of `names` in `range` compared with `baseline` — by default
    /// `range.previousPeriod`, the same number of days immediately before.
    public func comparison(
        of names: Set<EventName>,
        in range: DayRange,
        against baseline: DayRange? = nil,
        actors: Set<EventActor>? = nil
    ) async throws -> Comparison {
        let previous = baseline ?? range.previousPeriod
        let span = DayRange(start: min(range.start, previous.start), end: max(range.end, previous.end))
        let rows = try await dailyCounts(names: names, in: span, actors: actors)
        return Comparison(
            current: Double(rows.total(names: nil, in: range)),
            previous: Double(rows.total(names: nil, in: previous))
        )
    }

    // MARK: - Distributions

    /// Occurrences of `names` per weekday in `range`, in the calendar's week order.
    public func weekdayDistribution(of names: Set<EventName>, in range: DayRange, actors: Set<EventActor>? = nil) async throws -> [WeekdayBucket] {
        let rows = try await dailyCounts(names: names, in: range, actors: actors)
        return DistributionCalculator.weekdays(rows.valuesByDay(names: nil), in: range, calendar: calendar)
    }

    /// Occurrences of `names` per hour of day in `range` (24 buckets). Reads raw events, so days
    /// beyond the retention window contribute nothing.
    public func hourDistribution(of names: Set<EventName>, in range: DayRange) async throws -> [HourBucket] {
        guard !names.isEmpty else { return DistributionCalculator.hours([:]) }
        let rows = try await database.read { db in
            try AnalyticsEventRepository.hourlyCounts(names: names, in: range, in: db)
        }
        var totals: [Int: Double] = [:]
        for row in rows {
            totals[row.hour, default: 0] += Double(row.count)
        }
        return DistributionCalculator.hours(totals)
    }

    // MARK: - Usage and activity

    /// Total events, active days and per-module and per-actor counts in `range`. Module names
    /// are taken from `signals.moduleDisplayNames`.
    public func usageSummary(in range: DayRange, signals: ProductivitySignals = ProductivitySignals()) async throws -> UsageSummary {
        let rows = try await database.read { db in
            try DailyCountRepository.counts(names: nil, in: range, actors: nil, in: db)
        }
        return UsageSummaryBuilder.summary(rows, in: range, signals: signals)
    }

    /// The most recent recorded events, newest first, for an activity feed.
    public func recentEvents(limit: Int = 50, names: Set<EventName>? = nil) async throws -> [AnalyticsEventRecord] {
        if let names, names.isEmpty { return [] }
        return try await database.read { db in
            try AnalyticsEventRepository.recent(limit: limit, names: names, in: db)
        }
    }

    // MARK: - Internals

    func dailyCounts(names: Set<EventName>?, in range: DayRange, actors: Set<EventActor>?) async throws -> [DailyCount] {
        if let names, names.isEmpty { return [] }
        if let actors, actors.isEmpty { return [] }
        return try await database.read { db in
            try DailyCountRepository.counts(names: names, in: range, actors: actors, in: db)
        }
    }
}

private struct ErasedRows: Sendable {
    let events: Int
    let dailyCounts: Int
}
