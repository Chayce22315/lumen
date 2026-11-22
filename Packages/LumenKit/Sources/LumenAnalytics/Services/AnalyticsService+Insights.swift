import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

extension AnalyticsService {
    /// The data insights are generated from, as of `today` (default: today).
    public func activitySnapshot(signals: ProductivitySignals, today: CalendarDate? = nil) async throws -> ActivitySnapshot {
        let today = today ?? self.today()
        let window = DayRange.lastDays(generator.thresholds.lookbackDays, endingOn: today)
        let countedNames = signals.allEvents
        let hourNames = signals.completionEvents.union(signals.focusEvents)
        let completions = signals.completionEvents
        return try await database.read { db in
            ActivitySnapshot(
                today: today,
                window: window,
                dailyCounts: countedNames.isEmpty
                    ? []
                    : try DailyCountRepository.counts(names: countedNames, in: window, actors: nil, in: db),
                hourlyCounts: hourNames.isEmpty
                    ? []
                    : try AnalyticsEventRepository.hourlyCounts(names: hourNames, in: window, in: db),
                completionDays: try DailyCountRepository.activeDays(names: completions, through: today, in: db),
                firstRecordedDay: try DailyCountRepository.firstDay(in: db)
            )
        }
    }

    /// Ranked insights for `today` (default: today), at most `limit` (all when `nil`).
    public func insights(signals: ProductivitySignals, today: CalendarDate? = nil, limit: Int? = nil) async throws -> [Insight] {
        let snapshot = try await activitySnapshot(signals: signals, today: today)
        return generator.generate(
            from: snapshot,
            signals: signals,
            calendar: calendar,
            generatedAt: timeSource.now(),
            limit: limit
        )
    }

    /// The report for `range`, as of `today` (default: today). See `ReportBuilder` for how a
    /// running range is compared; its insights are generated as of the report's last covered day.
    public func report(
        signals: ProductivitySignals,
        range: DayRange,
        today: CalendarDate? = nil,
        insightLimit: Int? = nil
    ) async throws -> PeriodReport {
        let today = today ?? self.today()
        let asOf = min(range.end, today)
        let span = DayRange(start: range.previousPeriod.start, end: range.end)
        let completions = signals.completionEvents
        let inputs = try await database.read { db in
            ReportInputs(
                dailyCounts: try DailyCountRepository.counts(names: nil, in: span, actors: nil, in: db),
                completionDays: try DailyCountRepository.activeDays(names: completions, through: asOf, in: db)
            )
        }
        let insights = range.start <= asOf
            ? try await self.insights(signals: signals, today: asOf, limit: insightLimit)
            : []
        return ReportBuilder.build(
            range: range,
            today: today,
            signals: signals,
            dailyCounts: inputs.dailyCounts,
            completionDays: inputs.completionDays,
            calendar: calendar,
            insights: insights,
            generatedAt: timeSource.now()
        )
    }
}

private struct ReportInputs: Sendable {
    let dailyCounts: [DailyCount]
    let completionDays: Set<CalendarDate>
}
