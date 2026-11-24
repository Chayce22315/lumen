import Foundation

/// A short, specific observation about the user's own recorded activity.
///
/// Insights are derived only from recorded data and are produced only when the data clears the
/// thresholds in `InsightThresholds`; see `InsightGenerator` for the rules of each kind.
public struct Insight: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// Consecutive days with at least one completion. Metric: streak length in days.
        case streak
        /// Completions this week versus the same days last week. Metric: percent change.
        case weeklyTrend
        /// The weekday with the highest average completions. Metric: that weekday's average.
        case bestWeekday
        /// The hour of day with the most completion and focus activity. Metric: its share in percent.
        case bestHour
        /// Share of recent days with at least one completion. Metric: share in percent.
        case consistency
        /// Items created versus items completed. Metric: net change (created − completed).
        case workloadBalance
        /// Share of created and completed items handled by automations. Metric: share in percent.
        case automationShare
        /// Several full days without a recorded completion. Metric: days since the last one.
        case quietPeriod
    }

    public enum Tone: String, Sendable, Hashable, Codable {
        case positive
        case neutral
        case attention
    }

    /// Stable identifier built from the kind and its parameters
    /// (`weeklyTrend:current=14;previous=10;week=2026-11-16`). The same data yields the same id,
    /// so the interface can remember dismissals.
    public let id: String
    public let kind: Kind
    /// The values the insight was derived from, as display-safe strings (dates, counts, hours).
    public let parameters: [String: String]
    public let title: String
    public let detail: String
    public let tone: Tone
    /// The insight's headline number; its unit depends on `kind` (see the cases).
    public let metric: Double
    public let generatedAt: Date

    public init(
        kind: Kind,
        parameters: [String: String],
        title: String,
        detail: String,
        tone: Tone,
        metric: Double,
        generatedAt: Date
    ) {
        self.id = Insight.identifier(kind: kind, parameters: parameters)
        self.kind = kind
        self.parameters = parameters
        self.title = title
        self.detail = detail
        self.tone = tone
        self.metric = metric
        self.generatedAt = generatedAt
    }

    /// `kind:key=value;key=value` with keys in ascending order.
    public static func identifier(kind: Kind, parameters: [String: String]) -> String {
        let body = parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        return body.isEmpty ? kind.rawValue : "\(kind.rawValue):\(body)"
    }
}
