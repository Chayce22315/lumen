import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("ReportBuilder and Markdown")
struct ReportTests {
    let week = DayRange(start: day("2026-11-16"), end: day("2026-11-22"))

    /// Last week: 10 completed, 8 created. This week: 14 completed, 10 created, 2 focus, 5 notes.
    func activity() -> ActivityBuilder {
        var builder = ActivityBuilder()
        for (text, count) in [("2026-11-09", 2), ("2026-11-10", 3), ("2026-11-11", 1), ("2026-11-12", 2), ("2026-11-13", 2)] {
            builder.add(Fixture.completed, on: text, count: count)
        }
        builder.add(Fixture.created, on: "2026-11-09", count: 4)
        builder.add(Fixture.created, on: "2026-11-11", count: 4)
        for (text, count) in [
            ("2026-11-16", 3), ("2026-11-17", 4), ("2026-11-18", 2), ("2026-11-19", 1),
            ("2026-11-20", 2), ("2026-11-21", 1), ("2026-11-22", 1),
        ] {
            builder.add(Fixture.completed, on: text, count: count)
        }
        builder.add(Fixture.created, on: "2026-11-16", count: 2)
        builder.add(Fixture.created, on: "2026-11-17", count: 3)
        builder.add(Fixture.created, on: "2026-11-19", count: 5)
        builder.add(Fixture.focused, on: "2026-11-18", count: 2)
        builder.add(Fixture.noteEdited, on: "2026-11-17", count: 5)
        return builder
    }

    func report(
        _ builder: ActivityBuilder,
        range: DayRange,
        today: String,
        signals: ProductivitySignals = Fixture.signals,
        insights: [Insight] = []
    ) -> PeriodReport {
        ReportBuilder.build(
            range: range,
            today: day(today),
            signals: signals,
            dailyCounts: builder.counts,
            completionDays: builder.completionDays(signals: signals, through: day(today)),
            calendar: .testUTC,
            insights: insights,
            generatedAt: ManualTimeSource.referenceDate
        )
    }

    var sampleInsights: [Insight] {
        [
            Insight(kind: .weeklyTrend, parameters: ["week": "2026-11-16"], title: "Up 40% on last week",
                    detail: "You completed 14 tasks this week, 40% more than last week.", tone: .positive,
                    metric: 40, generatedAt: ManualTimeSource.referenceDate),
            Insight(kind: .streak, parameters: ["length": "7"], title: "7-day streak",
                    detail: "You've completed at least one task every day for 7 days.", tone: .positive,
                    metric: 7, generatedAt: ManualTimeSource.referenceDate),
        ]
    }

    @Test("a finished week is summarised and compared with the week before")
    func finishedWeek() {
        let report = report(activity(), range: week, today: "2026-11-22")
        #expect(report.asOf == day("2026-11-22"))
        #expect(report.previousRange == DayRange(start: day("2026-11-09"), end: day("2026-11-15")))
        #expect(report.completed == 14)
        #expect(report.completedComparison == Comparison(current: 14, previous: 10))
        #expect(report.created == 10)
        #expect(report.createdComparison?.percentChange == 25)
        #expect(report.focus == 2)
        #expect(report.focusComparison?.percentChange == nil)
        #expect(report.currentStreak == 7)
        #expect(report.longestStreak == 7)
        #expect(report.bestWeekday == .tuesday)
        #expect(report.dailyCompleted.values == [3, 4, 2, 1, 2, 1, 1])
        #expect(report.dailyCreated?.values == [2, 3, 0, 5, 0, 0, 0])
        #expect(report.modules.map(\.displayName) == ["Tasks", "Notes", "Focus"])
        #expect(report.modules.map(\.count) == [24, 5, 2])
    }

    @Test("a running week is compared with the same weekdays of the week before")
    func runningWeek() {
        var builder = activity()
        builder.add(Fixture.completed, on: "2026-11-15", count: 50) // last Sunday: outside the compared days
        let report = report(builder, range: week, today: "2026-11-21")
        #expect(report.asOf == day("2026-11-21"))
        #expect(report.previousRange == DayRange(start: day("2026-11-09"), end: day("2026-11-14")))
        #expect(report.completed == 13)
        #expect(report.completedComparison.previous == 10)
        #expect(report.dailyCompleted.points.count == 6)
        // The streak reaches back to last Sunday, before the range starts.
        #expect(report.currentStreak == 7)
        #expect(report.longestStreak == 6)
    }

    @Test("measures that are not configured are absent, not zero")
    func unconfiguredMeasures() {
        let report = report(activity(), range: week, today: "2026-11-22", signals: Fixture.completionOnly)
        #expect(report.created == nil)
        #expect(report.createdComparison == nil)
        #expect(report.focus == nil)
        #expect(report.dailyCreated == nil)
        let markdown = report.markdown()
        #expect(!markdown.contains("Created"))
        #expect(markdown.contains("| Day | Completed |\n"))
    }

    @Test("a period that has not started has no figures")
    func futurePeriod() {
        let next = week.shifted(byDays: 7)
        let report = report(activity(), range: next, today: "2026-11-22")
        #expect(report.completed == 0)
        #expect(report.dailyCompleted.isEmpty)
        #expect(report.modules.isEmpty)
        #expect(report.bestWeekday == nil)
        #expect(report.markdown().contains("This period has not started yet."))
    }

    @Test("the Markdown export matches the snapshot")
    func markdownSnapshot() {
        let markdown = report(activity(), range: week, today: "2026-11-22", insights: sampleInsights).markdown()
        let expected = """
            # Report: Mon 16 Nov 2026 – Sun 22 Nov 2026

            Covers Mon 16 Nov 2026 – Sun 22 Nov 2026, compared with Mon 9 Nov 2026 – Sun 15 Nov 2026.

            ## Summary

            | Measure | This period | Previous period | Change |
            | --- | ---: | ---: | ---: |
            | Completed tasks | 14 | 10 | +40% |
            | Created tasks | 10 | 8 | +25% |
            | Focus events | 2 | 0 | new |

            - Current streak: 7 days
            - Longest streak in this period: 7 days
            - Best weekday: Tuesday

            ## Per day

            | Day | Completed | Created |
            | --- | ---: | ---: |
            | Mon 16 Nov | 3 | 2 |
            | Tue 17 Nov | 4 | 3 |
            | Wed 18 Nov | 2 | 0 |
            | Thu 19 Nov | 1 | 5 |
            | Fri 20 Nov | 2 | 0 |
            | Sat 21 Nov | 1 | 0 |
            | Sun 22 Nov | 1 | 0 |

            ## Activity by module

            | Module | Events |
            | --- | ---: |
            | Tasks | 24 |
            | Notes | 5 |
            | Focus | 2 |

            ## Insights

            - **Up 40% on last week** — You completed 14 tasks this week, 40% more than last week.
            - **7-day streak** — You've completed at least one task every day for 7 days.

            """
        #expect(markdown == expected)
    }

    @Test("Markdown escapes table cells and reports empty sections honestly")
    func markdownEdges() {
        var signals = Fixture.signals
        signals.moduleDisplayNames["organization"] = "Tasks | Projects"
        var builder = ActivityBuilder()
        builder.add(Fixture.completed, on: "2026-11-20", count: 2)
        let markdown = report(builder, range: week, today: "2026-11-22", signals: signals).markdown()
        #expect(markdown.contains("| Tasks \\| Projects | 2 |"))
        #expect(markdown.contains("| Completed tasks | 2 | 0 | new |"))
        #expect(markdown.contains("| Created tasks | 0 | 0 | — |"))
        #expect(markdown.contains("Not enough recorded activity for insights yet."))
        #expect(!markdown.contains("Best weekday: Monday"))
        #expect(markdown.contains("- Best weekday: Friday"))
    }
}
