import Foundation
import LumenFoundation
import LumenCore

/// Assembles a `PeriodReport` from daily counts. Pure: the service gathers the inputs.
public enum ReportBuilder {
    /// Builds the report for `range` as of `today`.
    ///
    /// - A range that is still running is reported up to `today` only, and compared with the
    ///   same number of days at the start of the previous period (Monday–Saturday against the
    ///   previous Monday–Saturday), so an unfinished period is never compared with a finished one.
    /// - `dailyCounts` must cover `range.previousPeriod.start` through `range.end`; counts
    ///   outside that span are ignored.
    /// - `completionDays` is the full history of days with completions, so the current streak is
    ///   not cut off at the start of the range.
    public static func build(
        range: DayRange,
        today: CalendarDate,
        signals: ProductivitySignals,
        dailyCounts: [DailyCount],
        completionDays: Set<CalendarDate>,
        calendar: Calendar,
        insights: [Insight],
        generatedAt: Date
    ) -> PeriodReport {
        let asOf = min(range.end, today)
        // The days of the range that have happened; `nil` for a range that has not started.
        let covered: DayRange? = range.start <= asOf ? DayRange(start: range.start, end: asOf) : nil
        let coveredLength = covered?.dayCount ?? range.dayCount
        let previous = DayRange(
            start: range.previousPeriod.start,
            end: range.previousPeriod.start.adding(days: coveredLength - 1)
        )

        func total(_ names: Set<EventName>, in span: DayRange?) -> Int {
            guard let span else { return 0 }
            return dailyCounts.total(names: names, in: span)
        }
        func comparison(_ names: Set<EventName>) -> Comparison {
            Comparison(current: Double(total(names, in: covered)), previous: Double(total(names, in: previous)))
        }
        func series(_ names: Set<EventName>) -> TimeSeries {
            guard let covered else { return .empty }
            return SeriesBuilder.daily(dailyCounts.valuesByDay(names: names, in: covered), in: covered)
        }

        let completions = signals.completionEvents
        let creations = signals.creationEvents
        let focus = signals.focusEvents
        let completedValues = covered.map { dailyCounts.valuesByDay(names: completions, in: $0) } ?? [:]
        let bestWeekday = covered.flatMap { span in
            DistributionCalculator.bestWeekday(
                DistributionCalculator.weekdays(completedValues, in: span, calendar: calendar),
                calendar: calendar
            )?.weekday
        }

        return PeriodReport(
            range: range,
            previousRange: previous,
            asOf: asOf,
            completed: total(completions, in: covered),
            completedComparison: comparison(completions),
            created: creations.isEmpty ? nil : total(creations, in: covered),
            createdComparison: creations.isEmpty ? nil : comparison(creations),
            focus: focus.isEmpty ? nil : total(focus, in: covered),
            focusComparison: focus.isEmpty ? nil : comparison(focus),
            currentStreak: StreakCalculator.currentStreakLength(activeDays: completionDays, today: asOf),
            longestStreak: covered.flatMap { StreakCalculator.longestStreak(activeDays: completionDays, in: $0) }?.length ?? 0,
            bestWeekday: bestWeekday,
            dailyCompleted: series(completions),
            dailyCreated: creations.isEmpty ? nil : series(creations),
            modules: covered.map { UsageSummaryBuilder.modules(dailyCounts, in: $0, signals: signals) } ?? [],
            insights: insights,
            unit: signals.unit,
            generatedAt: generatedAt
        )
    }
}
