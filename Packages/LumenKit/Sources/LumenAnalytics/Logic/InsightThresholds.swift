import Foundation

/// The evidence an insight needs before it is shown. Defaults are deliberately conservative:
/// an insight that is not backed by enough data is worse than no insight.
public struct InsightThresholds: Sendable, Hashable {
    /// Days of history the generator looks at (ending today).
    public var lookbackDays: Int
    /// Shortest streak worth mentioning.
    public var minimumStreak: Int
    /// Completions required in *each* of the two compared periods before a trend is reported.
    public var minimumTrendEvents: Int
    /// Changes smaller than this (in percent, either direction) are reported as "about the same".
    public var steadyTrendPercent: Double
    /// Days of recorded history required before weekday, hour and consistency patterns are reported.
    public var minimumPatternDays: Int
    /// Completions required in the observed period before a best weekday is reported.
    public var minimumWeekdayEvents: Int
    /// How much the best weekday's average must exceed the other days' average (1.25 = 25 % more).
    public var minimumWeekdayLift: Double
    /// Completion and focus events required before a best hour is reported.
    public var minimumHourEvents: Int
    /// Share of activity (0…1) the best hour must hold.
    public var minimumHourShare: Double
    /// Days the consistency insight looks at.
    public var consistencyDays: Int
    /// Consistency at or above this share (0…1) is positive.
    public var highConsistency: Double
    /// Consistency at or below this share (0…1) needs attention.
    public var lowConsistency: Double
    /// Days the workload balance looks at.
    public var workloadDays: Int
    /// Created plus completed items required before workload balance is reported.
    public var minimumWorkloadEvents: Int
    /// Created ÷ completed at or above which the list counts as growing.
    public var workloadGrowthRatio: Double
    /// Days the automation share looks at.
    public var automationDays: Int
    /// Created plus completed items required before the automation share is reported.
    public var minimumAutomationEvents: Int
    /// Share (0…1) of that work automations must have done.
    public var minimumAutomationShare: Double
    /// Full days without a completion before a quiet period is reported.
    public var quietPeriodDays: Int
    /// Days with completions (ever) required before a quiet period is reported, so new users
    /// are not told they have been quiet.
    public var minimumQuietPeriodHistory: Int

    public init(
        lookbackDays: Int = 56,
        minimumStreak: Int = 3,
        minimumTrendEvents: Int = 5,
        steadyTrendPercent: Double = 10,
        minimumPatternDays: Int = 14,
        minimumWeekdayEvents: Int = 10,
        minimumWeekdayLift: Double = 1.25,
        minimumHourEvents: Int = 10,
        minimumHourShare: Double = 0.15,
        consistencyDays: Int = 28,
        highConsistency: Double = 0.7,
        lowConsistency: Double = 0.3,
        workloadDays: Int = 7,
        minimumWorkloadEvents: Int = 10,
        workloadGrowthRatio: Double = 1.5,
        automationDays: Int = 28,
        minimumAutomationEvents: Int = 10,
        minimumAutomationShare: Double = 0.1,
        quietPeriodDays: Int = 3,
        minimumQuietPeriodHistory: Int = 5
    ) {
        self.lookbackDays = max(14, lookbackDays)
        self.minimumStreak = max(2, minimumStreak)
        self.minimumTrendEvents = max(1, minimumTrendEvents)
        self.steadyTrendPercent = max(0, steadyTrendPercent)
        self.minimumPatternDays = max(7, minimumPatternDays)
        self.minimumWeekdayEvents = max(1, minimumWeekdayEvents)
        self.minimumWeekdayLift = max(1, minimumWeekdayLift)
        self.minimumHourEvents = max(1, minimumHourEvents)
        self.minimumHourShare = min(1, max(0, minimumHourShare))
        self.consistencyDays = max(7, consistencyDays)
        self.highConsistency = min(1, max(0, highConsistency))
        self.lowConsistency = min(1, max(0, lowConsistency))
        self.workloadDays = max(1, workloadDays)
        self.minimumWorkloadEvents = max(1, minimumWorkloadEvents)
        self.workloadGrowthRatio = max(1, workloadGrowthRatio)
        self.automationDays = max(1, automationDays)
        self.minimumAutomationEvents = max(1, minimumAutomationEvents)
        self.minimumAutomationShare = min(1, max(0, minimumAutomationShare))
        self.quietPeriodDays = max(1, quietPeriodDays)
        self.minimumQuietPeriodHistory = max(1, minimumQuietPeriodHistory)
    }

    public static let standard = InsightThresholds()
}
