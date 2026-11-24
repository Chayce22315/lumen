import Foundation
import Testing
import LumenFoundation
import LumenAnalytics
import LumenTestSupport

@Suite("DistributionCalculator")
struct DistributionCalculatorTests {
    let twoWeeks = DayRange(start: day("2026-11-09"), end: day("2026-11-22"))

    @Test("weekday buckets follow the calendar's week order")
    func weekdayOrder() {
        let monday = DistributionCalculator.weekdays([:], in: twoWeeks, calendar: .testUTC)
        #expect(monday.map(\.weekday) == [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday])
        let sunday = DistributionCalculator.weekdays([:], in: twoWeeks, calendar: Fixture.sundayFirstUTC)
        #expect(sunday.map(\.weekday) == [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday])
        #expect(monday.allSatisfy { $0.dayCount == 2 && $0.total == 0 })
    }

    @Test("averages account for weekdays that occur more often in the range")
    func unequalOccurrences() throws {
        // Monday 16 to Wednesday 25 November: Monday, Tuesday and Wednesday occur twice.
        let range = DayRange(start: day("2026-11-16"), end: day("2026-11-25"))
        let values: [CalendarDate: Double] = [day("2026-11-16"): 2, day("2026-11-23"): 2, day("2026-11-21"): 3]
        let buckets = DistributionCalculator.weekdays(values, in: range, calendar: .testUTC)
        let mondays = try #require(buckets.first { $0.weekday == .monday })
        #expect(mondays.total == 4)
        #expect(mondays.dayCount == 2)
        #expect(mondays.average == 2)
        // Saturday has the lower total but the higher average.
        #expect(DistributionCalculator.bestWeekday(buckets, calendar: .testUTC)?.weekday == .saturday)
    }

    @Test("weekday ties fall back to the total, then to the calendar's week order")
    func weekdayTies() {
        let equalAverages = [
            WeekdayBucket(weekday: .friday, total: 2, dayCount: 1),
            WeekdayBucket(weekday: .tuesday, total: 4, dayCount: 2),
        ]
        #expect(DistributionCalculator.bestWeekday(equalAverages, calendar: .testUTC)?.weekday == .tuesday)

        let identical = [
            WeekdayBucket(weekday: .sunday, total: 3, dayCount: 1),
            WeekdayBucket(weekday: .monday, total: 3, dayCount: 1),
        ]
        #expect(DistributionCalculator.bestWeekday(identical, calendar: .testUTC)?.weekday == .monday)
        #expect(DistributionCalculator.bestWeekday(identical, calendar: Fixture.sundayFirstUTC)?.weekday == .sunday)
        #expect(DistributionCalculator.rankedWeekdays(identical, calendar: .testUTC).map(\.weekday) == [.monday, .sunday])
    }

    @Test("there is no best weekday without activity")
    func noBestWeekday() {
        #expect(DistributionCalculator.bestWeekday(DistributionCalculator.weekdays([:], in: twoWeeks, calendar: .testUTC), calendar: .testUTC) == nil)
    }

    @Test("hour buckets cover the whole day and shares add up")
    func hours() {
        let buckets = DistributionCalculator.hours([9: 6, 14: 2, 23: 2, 24: 50, -1: 50])
        #expect(buckets.count == 24)
        #expect(buckets.map(\.hour) == Array(0...23))
        #expect(buckets[9].total == 6)
        #expect(buckets[9].share == 0.6)
        #expect(abs(buckets.map(\.share).reduce(0, +) - 1) < 1e-12)
        #expect(DistributionCalculator.hours([:]).allSatisfy { $0.share == 0 })
    }

    @Test("hour ties go to the earliest hour")
    func hourTies() {
        #expect(DistributionCalculator.bestHour(DistributionCalculator.hours([15: 4, 8: 4, 11: 1]))?.hour == 8)
        #expect(DistributionCalculator.bestHour(DistributionCalculator.hours([:])) == nil)
    }

    @Test("consistency is the share of active days in the range")
    func consistency() {
        let week = DayRange(start: day("2026-11-16"), end: day("2026-11-22"))
        let active = days("2026-11-16", "2026-11-18", "2026-11-20", "2026-11-01", "2026-11-30")
        #expect(DistributionCalculator.consistency(activeDays: active, in: week) == 3.0 / 7.0)
        #expect(DistributionCalculator.consistency(activeDays: [], in: week) == 0)
        #expect(DistributionCalculator.consistency(activeDays: Set(week.days), in: week) == 1)
    }
}
