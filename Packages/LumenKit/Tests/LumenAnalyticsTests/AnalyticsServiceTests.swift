import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("AnalyticsService")
struct AnalyticsServiceTests {
    let week = DayRange(start: day("2026-11-16"), end: day("2026-11-22"))

    /// Last week: 4 completions. This week: 6 completions (one automated), 3 creations,
    /// 2 note edits and a system event.
    func seeded() async throws -> AnalyticsHarness {
        let harness = try await AnalyticsHarness.make()
        for text in ["2026-11-09", "2026-11-10", "2026-11-10", "2026-11-12"] {
            try await harness.record(Fixture.completed, at: instant(text, hour: 10))
        }
        try await harness.record(Fixture.completed, at: instant("2026-11-16", hour: 9))
        try await harness.record(Fixture.completed, at: instant("2026-11-17", hour: 9))
        try await harness.record(Fixture.completed, at: instant("2026-11-17", hour: 9, minute: 30))
        try await harness.record(Fixture.completed, at: instant("2026-11-19", hour: 14))
        try await harness.record(Fixture.completed, at: instant("2026-11-20", hour: 9), actor: .automation)
        try await harness.record(Fixture.completed, at: instant("2026-11-21", hour: 8))
        try await harness.record(Fixture.created, at: instant("2026-11-16", hour: 8))
        try await harness.record(Fixture.created, at: instant("2026-11-18", hour: 8))
        try await harness.record(Fixture.created, at: instant("2026-11-18", hour: 20))
        try await harness.record(Fixture.noteEdited, at: instant("2026-11-18", hour: 21))
        try await harness.record(Fixture.noteEdited, at: instant("2026-11-19", hour: 21))
        try await harness.record("sync.run.finished", at: instant("2026-11-20", hour: 3), actor: .system)
        return harness
    }

    @Test("counts are zero-filled per requested name and filter by actor")
    func counts() async throws {
        let service = try await seeded().service
        let unknown: EventName = "plugins.thing.happened"
        #expect(try await service.counts(of: [Fixture.completed, Fixture.created, unknown], in: week)
            == [Fixture.completed: 6, Fixture.created: 3, unknown: 0])
        #expect(try await service.counts(of: [Fixture.completed], in: week, actors: [.automation]) == [Fixture.completed: 1])
        #expect(try await service.totalCount(of: [Fixture.completed, Fixture.created], in: week, actors: [.user]) == 8)
        #expect(try await service.counts(of: [], in: week).isEmpty)
        #expect(try await service.totalCount(of: [Fixture.completed], in: week, actors: []) == 0)
    }

    @Test("daily and weekly series are zero-filled")
    func series() async throws {
        let service = try await seeded().service
        let daily = try await service.dailySeries(of: [Fixture.completed], in: week)
        #expect(daily.days == week.days)
        #expect(daily.values == [1, 2, 0, 1, 1, 1, 0])
        let weekly = try await service.weeklySeries(of: [Fixture.completed], in: DayRange(start: day("2026-11-02"), end: day("2026-11-22")))
        #expect(weekly.days == [day("2026-11-02"), day("2026-11-09"), day("2026-11-16")])
        #expect(weekly.values == [0, 4, 6])
    }

    @Test("comparisons default to the previous period of the same length")
    func comparison() async throws {
        let service = try await seeded().service
        let comparison = try await service.comparison(of: [Fixture.completed], in: week)
        #expect(comparison.current == 6)
        #expect(comparison.previous == 4)
        #expect(comparison.percentChange == 50)
        let againstEmpty = try await service.comparison(of: [Fixture.completed], in: week, against: DayRange(start: day("2026-10-01"), end: day("2026-10-07")))
        #expect(againstEmpty.previous == 0)
        #expect(againstEmpty.percentChange == nil)
    }

    @Test("weekday and hour distributions")
    func distributions() async throws {
        let service = try await seeded().service
        let weekdays = try await service.weekdayDistribution(of: [Fixture.completed], in: week)
        #expect(weekdays.map(\.weekday).first == .monday)
        #expect(weekdays.map(\.total) == [1, 2, 0, 1, 1, 1, 0])
        let hours = try await service.hourDistribution(of: [Fixture.completed], in: week)
        #expect(hours.count == 24)
        #expect(hours[9].total == 4)
        #expect(hours[9].share == 4.0 / 6.0)
        #expect(DistributionCalculator.bestHour(hours)?.hour == 9)
        #expect(try await service.hourDistribution(of: [], in: week).allSatisfy { $0.total == 0 })
    }

    @Test("usage summaries count modules and actors and active days by the user")
    func usageSummary() async throws {
        let service = try await seeded().service
        let summary = try await service.usageSummary(in: week, signals: Fixture.signals)
        #expect(summary.totalEvents == 12)
        // 20 November had only automated and system events.
        #expect(summary.activeDays == 5)
        #expect(summary.modules.map(\.displayName) == ["Tasks", "Notes", "Sync"])
        #expect(summary.eventsPerModule == ["organization": 9, "knowledge": 2, "sync": 1])
        #expect(summary.actors.map(\.actor) == [.user, .automation, .system])
        #expect(summary.eventsPerActor[.user] == 10)
        #expect(abs(summary.activeShare - 5.0 / 7.0) < 1e-12)
    }

    @Test("recent events are newest first and can be limited and filtered")
    func recentEvents() async throws {
        let service = try await seeded().service
        let recent = try await service.recentEvents(limit: 3)
        #expect(recent.map(\.occurredAt) == [
            instant("2026-11-21", hour: 8), instant("2026-11-20", hour: 9), instant("2026-11-20", hour: 3),
        ])
        let created = try await service.recentEvents(names: [Fixture.created])
        #expect(created.count == 3)
        #expect(created.allSatisfy { $0.name == Fixture.created })
        #expect(try await service.recentEvents(names: []).isEmpty)
        #expect(try await service.recentEvents(limit: 0).count == 1)
    }

    @Test("insights are generated from recorded data")
    func insights() async throws {
        let service = try await seeded().service
        let insights = try await service.insights(signals: Fixture.signals)
        // 19, 20 and 21 November each have a completion; today is the 21st. Earlier runs were
        // two days long (9–10 and 16–17 November).
        let streak = try #require(insights.first(.streak))
        #expect(streak.detail == "You've completed at least one task every day for 3 days. It's your longest streak so far.")
        #expect(streak.generatedAt == ManualTimeSource.referenceDate)
        #expect(insights.first(.weeklyTrend) == nil) // 4 completions last week is below the threshold
        #expect(try await service.insights(signals: ProductivitySignals()).isEmpty)

        let snapshot = try await service.activitySnapshot(signals: Fixture.signals)
        #expect(snapshot.today == day("2026-11-21"))
        #expect(snapshot.firstRecordedDay == day("2026-11-09"))
        #expect(snapshot.completionDays.count == 8)
    }

    @Test("reports combine counts, comparisons, streaks and insights")
    func report() async throws {
        let service = try await seeded().service
        let report = try await service.report(signals: Fixture.signals, range: week)
        #expect(report.asOf == day("2026-11-21"))
        #expect(report.completed == 6)
        #expect(report.completedComparison.previous == 4)
        #expect(report.created == 3)
        #expect(report.focus == 0)
        #expect(report.currentStreak == 3)
        #expect(report.bestWeekday == .tuesday)
        #expect(report.insights.first(.streak) != nil)
        let markdown = report.markdown()
        #expect(markdown.hasPrefix("# Report: Mon 16 Nov 2026 – Sun 22 Nov 2026\n"))
        #expect(markdown.contains("| Completed tasks | 6 | 4 | +50% |"))
    }

    @Test("collection is on by default and the choice persists")
    func collectionSetting() async throws {
        let harness = try await AnalyticsHarness.make()
        #expect(await harness.service.isCollectionEnabled())
        try await harness.service.setCollectionEnabled(false)
        #expect(!(await harness.service.isCollectionEnabled()))
        let stored = await harness.environment.settings.value(AnalyticsSettings.collectionEnabled)
        #expect(stored == false)
    }

    @Test("erasing removes every event and count and announces it")
    func erase() async throws {
        let harness = try await seeded()
        let recorder = EventRecorder(bus: harness.environment.events, filter: EventFilter(names: [AnalyticsEvents.dataErased]))
        await harness.collector.start()

        try await harness.service.eraseAllData()
        #expect(try await harness.service.recentEvents().isEmpty)
        #expect(try await harness.service.totalCount(of: [Fixture.completed], in: DayRange.lastDays(365, endingOn: day("2026-11-21"))) == 0)
        #expect(try await harness.service.activitySnapshot(signals: Fixture.signals).firstRecordedDay == nil)
        #expect(try await harness.service.insights(signals: Fixture.signals).isEmpty)
        #expect(await recorder.waitForEvents(1).map(\.name) == [AnalyticsEvents.dataErased])

        // The running collector sees the announcement but does not record it.
        let statistics = await harness.waitForProcessed(17)
        #expect(statistics.ignored == 1)
        #expect(try await harness.service.recentEvents().isEmpty)
        await harness.collector.stop()
    }
}
