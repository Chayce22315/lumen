import Foundation
import Testing
import LumenFoundation
import LumenAnalytics
import LumenTestSupport

@Suite("SeriesBuilder")
struct SeriesBuilderTests {
    func series(_ values: [Double], from start: String = "2026-11-01") -> TimeSeries {
        let first = day(start)
        return TimeSeries(points: values.enumerated().map { TimeSeries.Point(day: first.adding(days: $0.offset), value: $0.element) })
    }

    @Test("daily series are zero-filled across a month boundary")
    func zeroFillMonth() {
        let range = DayRange(start: day("2026-01-30"), end: day("2026-02-02"))
        let result = SeriesBuilder.daily(counts: [day("2026-01-31"): 3, day("2026-02-02"): 1], in: range)
        #expect(result.granularity == .day)
        #expect(result.days == [day("2026-01-30"), day("2026-01-31"), day("2026-02-01"), day("2026-02-02")])
        #expect(result.values == [0, 3, 0, 1])
    }

    @Test("daily series are zero-filled across a year boundary and ignore values outside the range")
    func zeroFillYear() {
        let range = DayRange(start: day("2026-12-30"), end: day("2027-01-02"))
        let result = SeriesBuilder.daily([day("2027-01-01"): 2, day("2026-12-29"): 9, day("2027-01-03"): 9], in: range)
        #expect(result.values == [0, 0, 2, 0])
        #expect(result.total == 2)
        #expect(result.maximum == 2)
        #expect(result.value(on: day("2027-01-01")) == 2)
        #expect(result.value(on: day("2027-01-03")) == nil)
    }

    @Test("weekly buckets start on Monday for a Monday-first calendar")
    func weeklyMondayFirst() {
        // Wednesday 11 November through Tuesday 24 November, one event per day.
        let daily = SeriesBuilder.daily([:], in: DayRange(start: day("2026-11-11"), end: day("2026-11-24")))
        let ones = TimeSeries(points: daily.points.map { TimeSeries.Point(day: $0.day, value: 1) })
        let weekly = SeriesBuilder.weekly(ones, calendar: .testUTC)
        #expect(weekly.granularity == .week)
        #expect(weekly.days == [day("2026-11-09"), day("2026-11-16"), day("2026-11-23")])
        #expect(weekly.values == [5, 7, 2])
    }

    @Test("weekly buckets start on Sunday for a Sunday-first calendar")
    func weeklySundayFirst() {
        let values = Dictionary(uniqueKeysWithValues: DayRange(start: day("2026-11-11"), end: day("2026-11-24")).days.map { ($0, 1.0) })
        let weekly = SeriesBuilder.weekly(values, in: DayRange(start: day("2026-11-11"), end: day("2026-11-24")), calendar: Fixture.sundayFirstUTC)
        #expect(weekly.days == [day("2026-11-08"), day("2026-11-15"), day("2026-11-22")])
        #expect(weekly.values == [4, 7, 3])
    }

    @Test("weekly buckets are zero-filled and weekly or empty input passes through")
    func weeklyEdges() {
        let sparse = TimeSeries(points: [
            TimeSeries.Point(day: day("2026-11-02"), value: 2),
            TimeSeries.Point(day: day("2026-11-25"), value: 3),
        ])
        let weekly = SeriesBuilder.weekly(sparse, calendar: .testUTC)
        #expect(weekly.values == [2, 0, 0, 3])
        #expect(SeriesBuilder.weekly(weekly, calendar: .testUTC) == weekly)
        #expect(SeriesBuilder.weekly(.empty, calendar: .testUTC).isEmpty)
    }

    @Test("moving averages trail and average partial windows at the start")
    func movingAverage() {
        let averaged = SeriesBuilder.movingAverage(series([3, 6, 9, 12]), window: 3)
        #expect(averaged.values == [3, 4.5, 6, 9])
        #expect(averaged.days == series([3, 6, 9, 12]).days)
    }

    @Test("moving average windows of one or less return the series, larger windows a running mean")
    func movingAverageEdges() {
        let input = series([3, 6, 9, 12])
        #expect(SeriesBuilder.movingAverage(input, window: 1) == input)
        #expect(SeriesBuilder.movingAverage(input, window: 0) == input)
        #expect(SeriesBuilder.movingAverage(input, window: 10).values == [3, 4.5, 6, 7.5])
        #expect(SeriesBuilder.movingAverage(.empty, window: 7).isEmpty)
    }

    @Test("cumulative sums keep days and granularity")
    func cumulative() {
        let result = SeriesBuilder.cumulative(series([1, 0, 2, 5]))
        #expect(result.values == [1, 1, 3, 8])
        #expect(result.granularity == .day)
        #expect(SeriesBuilder.cumulative(.empty).isEmpty)
    }

    @Test("percent change is relative to the previous value and undefined from zero")
    func percentChange() {
        #expect(SeriesBuilder.percentChange(from: 10, to: 14) == 40)
        #expect(SeriesBuilder.percentChange(from: 8, to: 6) == -25)
        #expect(SeriesBuilder.percentChange(from: 5, to: 5) == 0)
        #expect(SeriesBuilder.percentChange(from: 0, to: 5) == nil)
        #expect(SeriesBuilder.percentChange(from: 0, to: 0) == nil)
    }

    @Test("comparisons carry absolute and relative change")
    func comparison() {
        let up = Comparison(current: 14, previous: 10)
        #expect(up.absoluteChange == 4)
        #expect(up.percentChange == 40)
        #expect(up.direction == .up)
        let fromZero = Comparison(current: 3, previous: 0)
        #expect(fromZero.percentChange == nil)
        #expect(fromZero.absoluteChange == 3)
        #expect(Comparison(current: 2, previous: 4).direction == .down)
        #expect(Comparison(current: 0, previous: 0).direction == .unchanged)
    }
}
