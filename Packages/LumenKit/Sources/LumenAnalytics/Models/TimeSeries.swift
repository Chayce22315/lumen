import Foundation
import LumenFoundation

/// A chart-ready series of values per day or per week.
///
/// Series built by `SeriesBuilder` are zero-filled: every day (or week) of the requested range
/// has a point, so charts never interpolate over missing data.
public struct TimeSeries: Sendable, Hashable, Codable {
    public enum Granularity: String, Sendable, Hashable, Codable {
        case day
        /// Each point is one calendar week; its `day` is the first day of that week.
        case week
    }

    public struct Point: Sendable, Hashable, Codable {
        public let day: CalendarDate
        public let value: Double

        public init(day: CalendarDate, value: Double) {
            self.day = day
            self.value = value
        }
    }

    public let granularity: Granularity
    public let points: [Point]

    public init(granularity: Granularity = .day, points: [Point]) {
        self.granularity = granularity
        self.points = points
    }

    public static let empty = TimeSeries(points: [])

    public var isEmpty: Bool { points.isEmpty }
    public var values: [Double] { points.map(\.value) }
    public var days: [CalendarDate] { points.map(\.day) }
    public var total: Double { values.reduce(0, +) }
    /// The largest value, or 0 for an empty series (convenient for chart scales).
    public var maximum: Double { values.max() ?? 0 }

    /// The value of the point for `day`, if the series has one.
    public func value(on day: CalendarDate) -> Double? {
        points.first(where: { $0.day == day })?.value
    }
}
