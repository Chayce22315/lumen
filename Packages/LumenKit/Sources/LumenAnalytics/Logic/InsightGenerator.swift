import Foundation
import LumenFoundation
import LumenCore

/// Turns recorded activity into a short, ranked list of honest insights.
///
/// The generator is pure and deterministic: the same snapshot, signals, calendar and thresholds
/// always produce the same insights in the same order, whatever the order of the input counts.
///
/// Every insight states only what the recorded data shows, and only once the data clears the
/// thresholds in `InsightThresholds`. Claims about a period ("this week", "the last 28 days")
/// are made only for days analytics was actually recording: periods are clipped to the days
/// since `ActivitySnapshot.firstRecordedDay`, and comparisons require both periods to be fully
/// recorded. The rules of each kind are documented on the rule functions in `InsightRules.swift`.
///
/// Ranking: each candidate gets a priority (attention-worthy and strongly evidenced insights
/// first); ties are broken by `Insight.Kind` declaration order, then by id. At most one insight
/// per kind is returned.
public struct InsightGenerator: Sendable {
    public let thresholds: InsightThresholds

    public init(thresholds: InsightThresholds = .standard) {
        self.thresholds = thresholds
    }

    /// Insights for `snapshot.today`, best first, at most `limit` of them (all when `nil`).
    public func generate(
        from snapshot: ActivitySnapshot,
        signals: ProductivitySignals,
        calendar: Calendar,
        generatedAt: Date,
        limit: Int? = nil
    ) -> [Insight] {
        let context = InsightContext(
            snapshot: snapshot,
            signals: signals,
            calendar: calendar,
            thresholds: thresholds,
            generatedAt: generatedAt
        )
        let candidates: [InsightCandidate] = [
            InsightRules.streak(context),
            InsightRules.weeklyTrend(context),
            InsightRules.bestWeekday(context),
            InsightRules.bestHour(context),
            InsightRules.consistency(context),
            InsightRules.workloadBalance(context),
            InsightRules.automationShare(context),
            InsightRules.quietPeriod(context),
        ].compactMap { $0 }
        return Self.rank(candidates, limit: limit)
    }

    static func rank(_ candidates: [InsightCandidate], limit: Int?) -> [Insight] {
        let kindOrder = Dictionary(uniqueKeysWithValues: Insight.Kind.allCases.enumerated().map { ($1, $0) })
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsKind = kindOrder[lhs.insight.kind] ?? 0
            let rhsKind = kindOrder[rhs.insight.kind] ?? 0
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            return lhs.insight.id < rhs.insight.id
        }
        var seenKinds = Set<Insight.Kind>()
        var seenIDs = Set<String>()
        var result: [Insight] = []
        for candidate in sorted {
            guard seenKinds.insert(candidate.insight.kind).inserted,
                  seenIDs.insert(candidate.insight.id).inserted else { continue }
            result.append(candidate.insight)
        }
        guard let limit else { return result }
        return Array(result.prefix(max(0, limit)))
    }
}

/// An insight with the priority used to rank it.
struct InsightCandidate: Sendable {
    let insight: Insight
    let priority: Double
}

/// The snapshot, normalized for the rules: counts limited to the window, history limited to today.
struct InsightContext: Sendable {
    let today: CalendarDate
    let window: DayRange
    let counts: [DailyCount]
    let hourly: [HourlyCount]
    let completionDays: Set<CalendarDate>
    let firstRecordedDay: CalendarDate?
    let signals: ProductivitySignals
    let calendar: Calendar
    let thresholds: InsightThresholds
    let generatedAt: Date

    init(snapshot: ActivitySnapshot, signals: ProductivitySignals, calendar: Calendar, thresholds: InsightThresholds, generatedAt: Date) {
        let today = snapshot.today
        // Days after `today` cannot hold data yet; a window entirely in the future degrades to today.
        let window = snapshot.window.start <= today
            ? DayRange(start: snapshot.window.start, end: min(snapshot.window.end, today))
            : DayRange(day: today)
        self.today = today
        self.window = window
        self.counts = snapshot.dailyCounts.filter { window.contains($0.day) }
        self.hourly = snapshot.hourlyCounts
        self.completionDays = snapshot.completionDays.filter { $0 <= today }
        self.firstRecordedDay = snapshot.firstRecordedDay
        self.signals = signals
        self.calendar = calendar
        self.thresholds = thresholds
        self.generatedAt = generatedAt
    }

    var unit: WorkUnit { signals.unit }
    var completions: Set<EventName> { signals.completionEvents }

    /// The days of `range` that lie in the window and were recorded (from the first recorded day
    /// through today). `nil` when none were.
    func observed(_ range: DayRange) -> DayRange? {
        guard let first = firstRecordedDay, first <= today else { return nil }
        return range.intersection(window)?.intersection(DayRange(start: first, end: today))
    }

    /// Whether analytics was recording for the whole of `range`.
    func isFullyRecorded(_ range: DayRange) -> Bool {
        guard let first = firstRecordedDay else { return false }
        return first <= range.start && window.contains(range.start) && range.end <= today
    }

    func insight(
        _ kind: Insight.Kind,
        parameters: [String: String],
        title: String,
        detail: String,
        tone: Insight.Tone,
        metric: Double,
        priority: Double
    ) -> InsightCandidate {
        InsightCandidate(
            insight: Insight(
                kind: kind,
                parameters: parameters,
                title: title,
                detail: detail,
                tone: tone,
                metric: metric,
                generatedAt: generatedAt
            ),
            priority: priority
        )
    }
}
