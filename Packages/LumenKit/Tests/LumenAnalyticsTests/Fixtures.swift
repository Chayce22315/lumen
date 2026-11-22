import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

enum Fixture {
    static let completed: EventName = "organization.task.completed"
    static let created: EventName = "organization.task.created"
    static let focused: EventName = "focus.session.finished"
    static let noteEdited: EventName = "knowledge.note.edited"

    static let tasks = WorkUnit(singular: "task", plural: "tasks")

    /// Signals as the application layer would configure them.
    static let signals = ProductivitySignals(
        completionEvents: [completed],
        creationEvents: [created],
        focusEvents: [focused],
        moduleDisplayNames: ["organization": "Tasks", "knowledge": "Notes"],
        unit: tasks
    )

    /// Same as `signals` without creation or focus events.
    static let completionOnly = ProductivitySignals(completionEvents: [completed], unit: tasks)

    static var sundayFirstUTC: Calendar {
        var calendar = Calendar.testUTC
        calendar.firstWeekday = 1
        return calendar
    }

    static func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar.testUTC
        calendar.timeZone = TimeZone(identifier: identifier) ?? calendar.timeZone
        return calendar
    }
}

/// A calendar date from `YYYY-MM-DD`; records an issue for malformed fixtures.
func day(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> CalendarDate {
    guard let value = CalendarDate(text) else {
        Issue.record("Invalid fixture date \(text)", sourceLocation: sourceLocation)
        return CalendarDate(ManualTimeSource.referenceDate, calendar: .testUTC)
    }
    return value
}

func days(_ texts: String...) -> Set<CalendarDate> {
    Set(texts.map { day($0) })
}

/// The instant `hour:minute` on `dayText` in `calendar`.
func instant(_ dayText: String, hour: Int, minute: Int = 0, calendar: Calendar = .testUTC) -> Date {
    day(dayText).startDate(in: calendar).addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
}

/// Builds the inputs of `InsightGenerator` and `ReportBuilder` day by day.
struct ActivityBuilder {
    var counts: [DailyCount] = []
    var hourly: [HourlyCount] = []
    /// Overrides the first recorded day (by default the earliest day with a count).
    var firstRecorded: CalendarDate?

    mutating func add(_ name: EventName, on dayText: String, count: Int = 1, actor: EventActor = .user) {
        counts.append(DailyCount(day: day(dayText), name: name, actor: actor, count: count))
    }

    /// `count` events of `name` on every day from `start` through `end`.
    mutating func addEveryDay(_ name: EventName, from start: String, through end: String, count: Int = 1, actor: EventActor = .user) {
        for date in DayRange(start: day(start), end: day(end)).days {
            counts.append(DailyCount(day: date, name: name, actor: actor, count: count))
        }
    }

    mutating func addHour(_ name: EventName, hour: Int, count: Int) {
        hourly.append(HourlyCount(name: name, hour: hour, count: count))
    }

    func completionDays(signals: ProductivitySignals, through today: CalendarDate) -> Set<CalendarDate> {
        Set(counts.filter { signals.completionEvents.contains($0.name) && $0.count > 0 && $0.day <= today }.map(\.day))
    }

    func snapshot(today todayText: String, signals: ProductivitySignals = Fixture.signals, lookbackDays: Int = 56) -> ActivitySnapshot {
        let today = day(todayText)
        return ActivitySnapshot(
            today: today,
            window: DayRange.lastDays(lookbackDays, endingOn: today),
            dailyCounts: counts,
            hourlyCounts: hourly,
            completionDays: completionDays(signals: signals, through: today),
            firstRecordedDay: firstRecorded ?? counts.map(\.day).min()
        )
    }

    func insights(
        today: String,
        signals: ProductivitySignals = Fixture.signals,
        calendar: Calendar = .testUTC,
        thresholds: InsightThresholds = .standard,
        limit: Int? = nil
    ) -> [Insight] {
        InsightGenerator(thresholds: thresholds).generate(
            from: snapshot(today: today, signals: signals, lookbackDays: thresholds.lookbackDays),
            signals: signals,
            calendar: calendar,
            generatedAt: ManualTimeSource.referenceDate,
            limit: limit
        )
    }
}

extension Array where Element == Insight {
    func first(_ kind: Insight.Kind) -> Insight? {
        first { $0.kind == kind }
    }
}

/// Analytics services over a fresh in-memory environment.
struct AnalyticsHarness {
    let environment: CoreTestEnvironment
    let collector: AnalyticsCollector
    let service: AnalyticsService

    static func make(calendar: Calendar = .testUTC, start: Date = ManualTimeSource.referenceDate) async throws -> AnalyticsHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [AnalyticsService.schema], start: start)
        let collector = AnalyticsCollector(
            database: environment.database,
            events: environment.events,
            settings: environment.settings,
            timeSource: environment.clock,
            calendar: calendar,
            logger: environment.logger("analytics")
        )
        let service = AnalyticsService(
            database: environment.database,
            settings: environment.settings,
            events: environment.events,
            timeSource: environment.clock,
            calendar: calendar,
            logger: environment.logger("analytics")
        )
        return AnalyticsHarness(environment: environment, collector: collector, service: service)
    }

    /// Records one event directly through the collector.
    @discardableResult
    func record(
        _ name: EventName,
        at date: Date,
        actor: EventActor = .user,
        entity: EntityReference? = nil,
        attributes: [String: JSONValue] = [:]
    ) async throws -> AnalyticsCollector.RecordOutcome {
        try await collector.record(DomainEvent(name: name, entity: entity, attributes: attributes, actor: actor, occurredAt: date))
    }

    /// Waits (bounded) until the collector has processed `count` events from its subscription.
    func waitForProcessed(_ count: Int, timeout: TimeInterval = 2) async -> AnalyticsCollector.Statistics {
        let deadline = Date().addingTimeInterval(timeout)
        var statistics = await collector.statistics()
        while statistics.processed < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // Polling pause; cancellation just ends the wait early.
            statistics = await collector.statistics()
        }
        return statistics
    }
}
