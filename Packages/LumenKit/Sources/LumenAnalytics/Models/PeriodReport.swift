import Foundation
import LumenFoundation

/// A summary of one period of work, compared with the period of the same length before it.
///
/// Measures whose events are not configured in `ProductivitySignals` are `nil` rather than 0:
/// "nothing created" and "creation is not tracked" are different statements.
public struct PeriodReport: Sendable, Hashable, Codable {
    public let range: DayRange
    /// The baseline of the comparisons: the start of `range.previousPeriod`, as many days long as
    /// the report covers, so a running week is compared with the same weekdays of the week before.
    public let previousRange: DayRange
    /// The last day the report's figures cover: `range.end`, or today when the range is still
    /// running. Days after it have no data yet and are left out of the series. For a range that
    /// has not started, `asOf` precedes `range.start` and the figures are empty.
    public let asOf: CalendarDate
    public let completed: Int
    public let completedComparison: Comparison
    /// `nil` when no creation events are configured.
    public let created: Int?
    public let createdComparison: Comparison?
    /// `nil` when no focus events are configured.
    public let focus: Int?
    public let focusComparison: Comparison?
    /// Consecutive days with a completion ending on `asOf` (or the day before, if `asOf` has none yet).
    public let currentStreak: Int
    /// The longest run of completion days inside the range.
    public let longestStreak: Int
    /// The weekday with the highest average completions in the range, `nil` without completions.
    public let bestWeekday: Weekday?
    /// Completions per day, zero-filled from `range.start` through `asOf`.
    public let dailyCompleted: TimeSeries
    /// Creations per day over the same days; `nil` when creation is not tracked.
    public let dailyCreated: TimeSeries?
    /// All recorded events in the range by module, most used first.
    public let modules: [ModuleUsage]
    public let insights: [Insight]
    /// The noun the report's text uses.
    public let unit: WorkUnit
    public let generatedAt: Date

    public init(
        range: DayRange,
        previousRange: DayRange,
        asOf: CalendarDate,
        completed: Int,
        completedComparison: Comparison,
        created: Int?,
        createdComparison: Comparison?,
        focus: Int?,
        focusComparison: Comparison?,
        currentStreak: Int,
        longestStreak: Int,
        bestWeekday: Weekday?,
        dailyCompleted: TimeSeries,
        dailyCreated: TimeSeries?,
        modules: [ModuleUsage],
        insights: [Insight],
        unit: WorkUnit,
        generatedAt: Date
    ) {
        self.range = range
        self.previousRange = previousRange
        self.asOf = asOf
        self.completed = completed
        self.completedComparison = completedComparison
        self.created = created
        self.createdComparison = createdComparison
        self.focus = focus
        self.focusComparison = focusComparison
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.bestWeekday = bestWeekday
        self.dailyCompleted = dailyCompleted
        self.dailyCreated = dailyCreated
        self.modules = modules
        self.insights = insights
        self.unit = unit
        self.generatedAt = generatedAt
    }

    /// The report as Markdown, for sharing or saving.
    public func markdown() -> String {
        ReportMarkdownRenderer.render(self)
    }
}
