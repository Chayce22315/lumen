import Foundation
import LumenFoundation
import LumenCore

/// How many times one event happened on one day, caused by one kind of actor. Mirrors a row of
/// `analytics_daily_counts`, which is kept even after raw events are purged.
public struct DailyCount: Sendable, Hashable, Codable {
    public let day: CalendarDate
    public let name: EventName
    public let actor: EventActor
    public let count: Int

    public init(day: CalendarDate, name: EventName, actor: EventActor, count: Int) {
        self.day = day
        self.name = name
        self.actor = actor
        self.count = max(0, count)
    }
}

/// How many times one event happened in one hour of the day (0–23) over some range of days.
public struct HourlyCount: Sendable, Hashable, Codable {
    public let name: EventName
    public let hour: Int
    public let count: Int

    public init(name: EventName, hour: Int, count: Int) {
        self.name = name
        self.hour = min(23, max(0, hour))
        self.count = max(0, count)
    }
}

/// Everything `InsightGenerator` looks at, gathered by the service in one read.
public struct ActivitySnapshot: Sendable, Hashable {
    /// The day insights are generated for.
    public let today: CalendarDate
    /// The lookback window `dailyCounts` and `hourlyCounts` cover; it ends on `today`.
    public let window: DayRange
    /// Daily counts within `window` (counts outside it are ignored).
    public let dailyCounts: [DailyCount]
    /// Hour-of-day counts within `window`.
    public let hourlyCounts: [HourlyCount]
    /// Every day, up to `today`, with at least one completion event — the full history, so
    /// streaks are not cut off by the window.
    public let completionDays: Set<CalendarDate>
    /// The earliest day analytics recorded anything at all. Insights that make claims about a
    /// period require the period to be covered by recorded data.
    public let firstRecordedDay: CalendarDate?

    public init(
        today: CalendarDate,
        window: DayRange,
        dailyCounts: [DailyCount],
        hourlyCounts: [HourlyCount],
        completionDays: Set<CalendarDate>,
        firstRecordedDay: CalendarDate?
    ) {
        self.today = today
        self.window = window
        self.dailyCounts = dailyCounts
        self.hourlyCounts = hourlyCounts
        self.completionDays = completionDays
        self.firstRecordedDay = firstRecordedDay
    }
}
