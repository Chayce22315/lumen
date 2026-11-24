import Foundation
import LumenFoundation

/// Builds and transforms chart-ready series.
public enum SeriesBuilder {
    /// A daily series with one point per day of `range`; days without a value are 0 and values
    /// for days outside the range are ignored.
    public static func daily(_ values: [CalendarDate: Double], in range: DayRange) -> TimeSeries {
        TimeSeries(granularity: .day, points: range.days.map { TimeSeries.Point(day: $0, value: values[$0] ?? 0) })
    }

    /// `daily(_:in:)` for integer counts.
    public static func daily(counts: [CalendarDate: Int], in range: DayRange) -> TimeSeries {
        daily(counts.mapValues(Double.init), in: range)
    }

    /// Sums a daily series into calendar weeks that start on `calendar.firstWeekday`.
    ///
    /// Every week from the one containing the first point to the one containing the last point
    /// gets a point (zero-filled). A point's `day` is the first day of its week, which can precede
    /// the series' first day: when the series starts or ends mid-week, those edge weeks only sum
    /// the days the series has. A series that is already weekly is returned unchanged.
    public static func weekly(_ series: TimeSeries, calendar: Calendar) -> TimeSeries {
        guard series.granularity == .day else { return series }
        guard let firstDay = series.points.map(\.day).min(), let lastDay = series.points.map(\.day).max() else {
            return TimeSeries(granularity: .week, points: [])
        }
        var sums: [CalendarDate: Double] = [:]
        for point in series.points {
            sums[WeekMath.startOfWeek(containing: point.day, calendar: calendar), default: 0] += point.value
        }
        let firstWeek = WeekMath.startOfWeek(containing: firstDay, calendar: calendar)
        let lastWeek = WeekMath.startOfWeek(containing: lastDay, calendar: calendar)
        let weekCount = lastWeek.days(since: firstWeek) / 7 + 1
        let points = (0..<weekCount).map { index -> TimeSeries.Point in
            let week = firstWeek.adding(days: index * 7)
            return TimeSeries.Point(day: week, value: sums[week] ?? 0)
        }
        return TimeSeries(granularity: .week, points: points)
    }

    /// Weekly sums of `values` over `range` (see `weekly(_:calendar:)` for partial edge weeks).
    public static func weekly(_ values: [CalendarDate: Double], in range: DayRange, calendar: Calendar) -> TimeSeries {
        weekly(daily(values, in: range), calendar: calendar)
    }

    /// Trailing moving average over `window` points, keeping the series' length.
    ///
    /// Point *i* averages points *i − window + 1 … i*. The first `window − 1` points have fewer
    /// predecessors and average the points available so far, so the curve starts at the first
    /// value instead of being pulled towards zero. A `window` of 1 or less returns the series unchanged.
    public static func movingAverage(_ series: TimeSeries, window: Int) -> TimeSeries {
        guard window > 1 else { return series }
        let values = series.values
        let points = series.points.indices.map { index -> TimeSeries.Point in
            let lower = max(0, index - window + 1)
            let slice = values[lower...index]
            let average = slice.reduce(0, +) / Double(slice.count)
            return TimeSeries.Point(day: series.points[index].day, value: average)
        }
        return TimeSeries(granularity: series.granularity, points: points)
    }

    /// Running total: point *i* is the sum of points *0 … i*.
    public static func cumulative(_ series: TimeSeries) -> TimeSeries {
        var running = 0.0
        let points = series.points.map { point -> TimeSeries.Point in
            running += point.value
            return TimeSeries.Point(day: point.day, value: running)
        }
        return TimeSeries(granularity: series.granularity, points: points)
    }

    /// Relative change from `previous` to `current`, in percent (+40 means 40 % more).
    /// `nil` when `previous` is 0: a change from nothing has no meaningful percentage.
    public static func percentChange(from previous: Double, to current: Double) -> Double? {
        guard previous != 0, previous.isFinite, current.isFinite else { return nil }
        return (current - previous) / abs(previous) * 100
    }
}
