import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

private let completed = Fixture.completed
private let created = Fixture.created
private let focused = Fixture.focused

@Suite("InsightGenerator: general rules")
struct InsightGeneralTests {
    @Test("no recorded data produces no insights")
    func empty() {
        #expect(ActivityBuilder().insights(today: "2026-11-22").isEmpty)
    }

    @Test("without configured signals nothing is claimed, however much data there is")
    func noSignals() {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-10-01", through: "2026-11-22", count: 3)
        #expect(builder.insights(today: "2026-11-22", signals: ProductivitySignals()).isEmpty)
    }

    /// A week with a 40 % rise, a 7-day streak, a growing list and steady consistency.
    func richBuilder() -> ActivityBuilder {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-09", through: "2026-11-13", count: 2)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-22", count: 2)
        builder.addEveryDay(created, from: "2026-11-16", through: "2026-11-22", count: 5)
        return builder
    }

    @Test("insights are ranked by priority with one insight per kind")
    func ranking() {
        let insights = richBuilder().insights(today: "2026-11-22")
        #expect(insights.map(\.kind) == [.workloadBalance, .weeklyTrend, .streak, .consistency])
        #expect(Set(insights.map(\.kind)).count == insights.count)
        #expect(Set(insights.map(\.id)).count == insights.count)
        #expect(richBuilder().insights(today: "2026-11-22", limit: 2).map(\.kind) == [.workloadBalance, .weeklyTrend])
        #expect(richBuilder().insights(today: "2026-11-22", limit: 0).isEmpty)
    }

    @Test("generation is deterministic regardless of input order and generation time")
    func determinism() {
        let builder = richBuilder()
        var shuffled = builder
        shuffled.counts = builder.counts.reversed()
        let first = builder.insights(today: "2026-11-22")
        #expect(shuffled.insights(today: "2026-11-22") == first)

        let later = InsightGenerator().generate(
            from: builder.snapshot(today: "2026-11-22"),
            signals: Fixture.signals,
            calendar: .testUTC,
            generatedAt: ManualTimeSource.referenceDate.addingTimeInterval(3_600)
        )
        #expect(later.map(\.id) == first.map(\.id))
        #expect(later.map(\.detail) == first.map(\.detail))
    }

    @Test("identifiers combine the kind with sorted parameters")
    func identifiers() {
        #expect(Insight.identifier(kind: .weeklyTrend, parameters: ["week": "2026-11-16", "current": "14", "previous": "10"])
            == "weeklyTrend:current=14;previous=10;week=2026-11-16")
        #expect(Insight.identifier(kind: .streak, parameters: [:]) == "streak")
    }
}

@Suite("InsightGenerator: streaks and trends")
struct InsightStreakTrendTests {
    @Test("streaks shorter than three days are not mentioned")
    func shortStreak() {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-21", through: "2026-11-22")
        #expect(builder.insights(today: "2026-11-22").first(.streak) == nil)
    }

    @Test("a streak through today is positive and specific")
    func streakToday() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-20", through: "2026-11-22")
        let insight = try #require(builder.insights(today: "2026-11-22").first(.streak))
        #expect(insight.title == "3-day streak")
        #expect(insight.detail == "You've completed at least one task every day for 3 days.")
        #expect(insight.tone == .positive)
        #expect(insight.metric == 3)
        #expect(insight.id == "streak:length=3;start=2026-11-20")
    }

    @Test("a streak through yesterday nudges to keep it going")
    func streakYesterday() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-19", through: "2026-11-21")
        let insight = try #require(builder.insights(today: "2026-11-22").first(.streak))
        #expect(insight.detail == "You completed at least one task on each of the 3 days up to yesterday. Complete one today to keep it going.")
        #expect(insight.tone == .neutral)
    }

    @Test("a record is mentioned only when it beats an earlier streak")
    func streakRecord() throws {
        var beaten = ActivityBuilder()
        beaten.addEveryDay(completed, from: "2026-11-10", through: "2026-11-11")
        beaten.addEveryDay(completed, from: "2026-11-20", through: "2026-11-22")
        let record = try #require(beaten.insights(today: "2026-11-22").first(.streak))
        #expect(record.detail == "You've completed at least one task every day for 3 days. It's your longest streak so far.")

        var notBeaten = ActivityBuilder()
        notBeaten.addEveryDay(completed, from: "2026-11-05", through: "2026-11-08")
        notBeaten.addEveryDay(completed, from: "2026-11-20", through: "2026-11-22")
        let plain = try #require(notBeaten.insights(today: "2026-11-22").first(.streak))
        #expect(!plain.detail.contains("longest"))
    }

    @Test("a completed week reports the change against last week")
    func trendUp() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-09", through: "2026-11-13", count: 2)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-22", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.weeklyTrend))
        #expect(insight.detail == "You completed 14 tasks this week, 40% more than last week.")
        #expect(insight.title == "Up 40% on last week")
        #expect(insight.tone == .positive)
        #expect(insight.metric == 40)
        #expect(insight.id == "weeklyTrend:current=14;previous=10;week=2026-11-16")
    }

    @Test("mid-week trends compare with the same days of last week")
    func trendMidWeek() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-09", through: "2026-11-14", count: 1)
        builder.addEveryDay(completed, from: "2026-11-15", through: "2026-11-15", count: 9) // last Sunday: not compared yet
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-21", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-21").first(.weeklyTrend))
        #expect(insight.detail == "You completed 12 tasks this week, 100% more than by this point last week.")
    }

    @Test("a drop is flagged and quotes last week's figure")
    func trendDown() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-09", through: "2026-11-14", count: 2)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-18", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.weeklyTrend))
        #expect(insight.title == "Down 50% on last week")
        #expect(insight.detail == "You completed 6 tasks this week, 50% fewer than last week (12).")
        #expect(insight.tone == .attention)
    }

    @Test("small changes read as a steady week")
    func trendSteady() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-09", through: "2026-11-14", count: 2)
        builder.add(completed, on: "2026-11-15")
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-22", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.weeklyTrend))
        #expect(insight.title == "Steady week")
        #expect(insight.detail == "You completed 14 tasks this week, about the same as last week (13).")
        #expect(insight.tone == .neutral)
    }

    @Test("trends need five completions in each week")
    func trendThreshold() {
        var fewNow = ActivityBuilder()
        fewNow.addEveryDay(completed, from: "2026-11-09", through: "2026-11-13", count: 2)
        fewNow.add(completed, on: "2026-11-16", count: 4)
        #expect(fewNow.insights(today: "2026-11-22").first(.weeklyTrend) == nil)

        var fewBefore = ActivityBuilder()
        fewBefore.add(completed, on: "2026-11-09", count: 4)
        fewBefore.add(completed, on: "2026-11-16", count: 10)
        #expect(fewBefore.insights(today: "2026-11-22").first(.weeklyTrend) == nil)
    }

    @Test("trends need last week to have been recorded in full")
    func trendNeedsRecordedBaseline() {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-12", through: "2026-11-22", count: 2)
        #expect(builder.insights(today: "2026-11-22").first(.weeklyTrend) == nil)
    }

    @Test("weeks follow the calendar's first weekday")
    func trendSundayFirst() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-08", through: "2026-11-14", count: 1)
        builder.addEveryDay(completed, from: "2026-11-15", through: "2026-11-21", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-21", calendar: Fixture.sundayFirstUTC).first(.weeklyTrend))
        #expect(insight.detail == "You completed 14 tasks this week, 100% more than last week.")
        #expect(insight.parameters["week"] == "2026-11-15")
    }
}

@Suite("InsightGenerator: patterns")
struct InsightPatternTests {
    /// One completion a day from Monday 9 to Sunday 22 November, five on Tuesdays.
    func tuesdays(from start: String = "2026-11-09", thursdays: Int = 1) -> ActivityBuilder {
        var builder = ActivityBuilder()
        for date in DayRange(start: day(start), end: day("2026-11-22")).days {
            let count: Int
            switch date.isoWeekday {
            case 2: count = 5
            case 4: count = thursdays
            default: count = 1
            }
            builder.counts.append(DailyCount(day: date, name: completed, actor: .user, count: count))
        }
        return builder
    }

    @Test("the best weekday is reported after two weeks of data")
    func bestWeekday() throws {
        let insight = try #require(tuesdays().insights(today: "2026-11-22").first(.bestWeekday))
        #expect(insight.title == "Tuesday is your best day")
        #expect(insight.detail == "Over the last 2 weeks you completed 5 tasks on an average Tuesday, compared with 1 on other days.")
        #expect(insight.metric == 5)
        #expect(insight.id == "bestWeekday:days=14;weekday=tuesday")
    }

    @Test("no best weekday with less than two weeks of data")
    func bestWeekdayNeedsTwoWeeks() {
        #expect(tuesdays(from: "2026-11-10").insights(today: "2026-11-22").first(.bestWeekday) == nil)
    }

    @Test("no best weekday when two weekdays tie or the lead is small")
    func bestWeekdayTieOrWeakLead() {
        #expect(tuesdays(thursdays: 5).insights(today: "2026-11-22").first(.bestWeekday) == nil)

        var weak = ActivityBuilder()
        weak.addEveryDay(completed, from: "2026-11-09", through: "2026-11-22", count: 4)
        weak.add(completed, on: "2026-11-10") // Tuesdays average 4.5 against 4 elsewhere
        #expect(weak.insights(today: "2026-11-22").first(.bestWeekday) == nil)
    }

    @Test("the best hour counts completions and focus activity")
    func bestHour() throws {
        var builder = tuesdays()
        builder.addHour(completed, hour: 9, count: 6)
        builder.addHour(focused, hour: 14, count: 3)
        builder.addHour(completed, hour: 20, count: 3)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.bestHour))
        #expect(insight.title == "Most productive around 09:00")
        #expect(insight.detail == "50% of your completions and focus activity over the last 2 weeks happened between 09:00 and 10:00.")
        #expect(insight.metric == 50)

        var completionsOnly = tuesdays()
        completionsOnly.addHour(completed, hour: 9, count: 6)
        completionsOnly.addHour(completed, hour: 20, count: 4)
        completionsOnly.addHour(focused, hour: 14, count: 30) // not configured, so not counted
        let plain = try #require(completionsOnly.insights(today: "2026-11-22", signals: Fixture.completionOnly).first(.bestHour))
        #expect(plain.detail == "60% of your completed tasks over the last 2 weeks happened between 09:00 and 10:00.")
    }

    @Test("no best hour on ties or with too few events")
    func bestHourThresholds() {
        var tie = tuesdays()
        tie.addHour(completed, hour: 9, count: 5)
        tie.addHour(completed, hour: 14, count: 5)
        #expect(tie.insights(today: "2026-11-22").first(.bestHour) == nil)

        var few = tuesdays()
        few.addHour(completed, hour: 9, count: 5)
        few.addHour(completed, hour: 14, count: 4)
        #expect(few.insights(today: "2026-11-22").first(.bestHour) == nil)
    }

    @Test("high consistency over the last four weeks is positive")
    func consistencyHigh() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-10-26", through: "2026-11-13")
        builder.addEveryDay(completed, from: "2026-11-20", through: "2026-11-22")
        let insight = try #require(builder.insights(today: "2026-11-22").first(.consistency))
        #expect(insight.title == "Consistent rhythm")
        #expect(insight.detail == "You completed at least one task on 22 of the last 28 days.")
        #expect(insight.tone == .positive)
        #expect(abs(insight.metric - 22.0 / 28.0 * 100) < 1e-9)
    }

    @Test("low consistency needs attention and an unfinished today is not counted")
    func consistencyLow() throws {
        var builder = ActivityBuilder()
        builder.add(Fixture.noteEdited, on: "2026-10-20")
        for text in ["2026-10-27", "2026-11-02", "2026-11-08", "2026-11-14", "2026-11-20"] {
            builder.add(completed, on: text)
        }
        let insights = builder.insights(today: "2026-11-22")
        let insight = try #require(insights.first(.consistency))
        #expect(insight.title == "An irregular rhythm")
        #expect(insight.detail == "You completed at least one task on 5 of the 28 days before today.")
        #expect(insight.tone == .attention)
        #expect(insights.first(.quietPeriod) == nil)
    }

    @Test("consistency needs two weeks of recorded days")
    func consistencyNeedsHistory() {
        var builder = ActivityBuilder()
        builder.addEveryDay(completed, from: "2026-11-13", through: "2026-11-22")
        #expect(builder.insights(today: "2026-11-22").first(.consistency) == nil)
    }
}

@Suite("InsightGenerator: workload, automation and quiet periods")
struct InsightWorkloadTests {
    @Test("a list that grows faster than it is cleared needs attention")
    func workloadGrowing() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(created, from: "2026-11-16", through: "2026-11-21", count: 4)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-21", count: 2)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.workloadBalance))
        #expect(insight.title == "Your list is growing")
        #expect(insight.detail == "You added 24 tasks and completed 12 in the last 7 days.")
        #expect(insight.tone == .attention)
        #expect(insight.metric == 12)
    }

    @Test("completing more than was added is positive")
    func workloadClearing() throws {
        var builder = ActivityBuilder()
        builder.addEveryDay(created, from: "2026-11-16", through: "2026-11-21", count: 2)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-21", count: 3)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.workloadBalance))
        #expect(insight.title == "You're clearing your list")
        #expect(insight.detail == "You completed 18 tasks and added 12 in the last 7 days.")
        #expect(insight.metric == -6)
    }

    @Test("workload balance needs creation events and enough activity")
    func workloadThresholds() {
        var builder = ActivityBuilder()
        builder.addEveryDay(created, from: "2026-11-16", through: "2026-11-21", count: 4)
        builder.addEveryDay(completed, from: "2026-11-16", through: "2026-11-21", count: 2)
        #expect(builder.insights(today: "2026-11-22", signals: Fixture.completionOnly).first(.workloadBalance) == nil)

        var quiet = ActivityBuilder()
        quiet.add(created, on: "2026-11-20", count: 4)
        quiet.add(completed, on: "2026-11-21", count: 5)
        #expect(quiet.insights(today: "2026-11-22").first(.workloadBalance) == nil)
    }

    @Test("automation share counts automated creations and completions")
    func automationShare() throws {
        var builder = ActivityBuilder()
        builder.add(Fixture.noteEdited, on: "2026-10-26")
        builder.add(completed, on: "2026-11-02", count: 20)
        builder.add(created, on: "2026-11-03", count: 8)
        builder.add(completed, on: "2026-11-04", count: 12, actor: .automation)
        let insight = try #require(builder.insights(today: "2026-11-22").first(.automationShare))
        #expect(insight.detail == "Automations created or completed 12 of 40 tasks (30%) in the last 4 weeks.")
        #expect(insight.metric == 30)

        let completionsOnly = try #require(builder.insights(today: "2026-11-22", signals: Fixture.completionOnly).first(.automationShare))
        #expect(completionsOnly.detail == "Automations completed 12 of 32 tasks (38%) in the last 4 weeks.")
    }

    @Test("a small automated share is not reported")
    func automationShareThreshold() {
        var builder = ActivityBuilder()
        builder.add(completed, on: "2026-11-02", count: 38)
        builder.add(completed, on: "2026-11-04", count: 2, actor: .automation)
        #expect(builder.insights(today: "2026-11-22").first(.automationShare) == nil)
    }

    @Test("several full days without a completion are a quiet stretch")
    func quietPeriod() throws {
        var builder = ActivityBuilder()
        for text in ["2026-11-01", "2026-11-03", "2026-11-05", "2026-11-09", "2026-11-17"] {
            builder.add(completed, on: text)
        }
        let insight = try #require(builder.insights(today: "2026-11-21").first(.quietPeriod))
        #expect(insight.title == "Quiet stretch")
        #expect(insight.detail == "No completed tasks recorded since Tue 17 Nov, 4 days ago.")
        #expect(insight.tone == .attention)
        #expect(insight.metric == 4)
        #expect(insight.id == "quietPeriod:last=2026-11-17")
    }

    @Test("quiet stretches need three full days and an established history")
    func quietPeriodThresholds() {
        var recent = ActivityBuilder()
        for text in ["2026-11-01", "2026-11-03", "2026-11-05", "2026-11-09", "2026-11-18"] {
            recent.add(completed, on: text)
        }
        #expect(recent.insights(today: "2026-11-21").first(.quietPeriod) == nil)

        var newcomer = ActivityBuilder()
        for text in ["2026-11-01", "2026-11-03", "2026-11-05", "2026-11-09"] {
            newcomer.add(completed, on: text)
        }
        #expect(newcomer.insights(today: "2026-11-21").first(.quietPeriod) == nil)
    }
}
