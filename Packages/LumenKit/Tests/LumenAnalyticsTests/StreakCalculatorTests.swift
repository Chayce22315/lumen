import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAnalytics
import LumenTestSupport

@Suite("StreakCalculator")
struct StreakCalculatorTests {
    let today = day("2026-11-21")

    @Test("no activity means no streak")
    func empty() {
        #expect(StreakCalculator.currentStreak(activeDays: [], today: today) == nil)
        #expect(StreakCalculator.currentStreakLength(activeDays: [], today: today) == 0)
        #expect(StreakCalculator.longestStreak(activeDays: [], in: DayRange.lastDays(30, endingOn: today)) == nil)
    }

    @Test("a streak that includes today ends today")
    func endsToday() throws {
        let streak = try #require(StreakCalculator.currentStreak(activeDays: days("2026-11-19", "2026-11-20", "2026-11-21"), today: today))
        #expect(streak.start == day("2026-11-19"))
        #expect(streak.end == today)
        #expect(streak.length == 3)
    }

    @Test("an empty today does not break a streak that ran through yesterday")
    func todayEmptyYesterdayFull() throws {
        let streak = try #require(StreakCalculator.currentStreak(activeDays: days("2026-11-18", "2026-11-19", "2026-11-20"), today: today))
        #expect(streak.end == day("2026-11-20"))
        #expect(streak.length == 3)
    }

    @Test("a streak whose last day was before yesterday is over")
    func broken() {
        #expect(StreakCalculator.currentStreak(activeDays: days("2026-11-17", "2026-11-18", "2026-11-19"), today: today) == nil)
    }

    @Test("gaps end streaks")
    func gaps() {
        let active = days("2026-11-15", "2026-11-16", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21")
        #expect(StreakCalculator.currentStreakLength(activeDays: active, today: today) == 4)
        let runs = StreakCalculator.streaks(activeDays: active, in: DayRange.lastDays(14, endingOn: today))
        #expect(runs.map(\.length) == [2, 4])
        #expect(runs.first?.start == day("2026-11-15"))
    }

    @Test("days after today are ignored")
    func futureDays() {
        #expect(StreakCalculator.currentStreakLength(activeDays: days("2026-11-21", "2026-11-22", "2026-11-23"), today: today) == 1)
    }

    @Test("streaks run across month and year boundaries")
    func acrossYearBoundary() {
        let active = days("2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02")
        #expect(StreakCalculator.currentStreakLength(activeDays: active, today: day("2027-01-02")) == 4)
        #expect(StreakCalculator.currentStreakLength(activeDays: days("2026-02-28", "2026-03-01"), today: day("2026-03-01")) == 2)
    }

    @Test("the longest streak in a range is the longest run, the earliest on ties")
    func longest() throws {
        let active = days(
            "2026-11-01", "2026-11-02", "2026-11-03",
            "2026-11-05", "2026-11-06", "2026-11-07",
            "2026-11-10"
        )
        let longest = try #require(StreakCalculator.longestStreak(activeDays: active, in: DayRange(start: day("2026-11-01"), end: day("2026-11-30"))))
        #expect(longest.length == 3)
        #expect(longest.start == day("2026-11-01"))
    }

    @Test("runs that cross the range edge are clipped to the range")
    func clipped() throws {
        let active = Set(DayRange(start: day("2026-10-25"), end: day("2026-11-04")).days)
        let longest = try #require(StreakCalculator.longestStreak(activeDays: active, in: DayRange(start: day("2026-11-01"), end: day("2026-11-30"))))
        #expect(longest.start == day("2026-11-01"))
        #expect(longest.length == 4)
    }

    @Test("day boundaries follow the recording calendar's time zone")
    func timeZoneBoundaries() {
        // 03:00 and 20:00 UTC on 21 November.
        let early = DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-21", hour: 3))
        let late = DomainEvent(name: Fixture.completed, occurredAt: instant("2026-11-21", hour: 20))

        let utcDays = Set([early, late].map { AnalyticsEventRecord(event: $0, calendar: .testUTC).day })
        #expect(utcDays == days("2026-11-21"))
        #expect(StreakCalculator.currentStreakLength(activeDays: utcDays, today: today) == 1)

        // In Los Angeles (UTC−8) the first event happened the evening before.
        let losAngeles = Fixture.calendar(timeZone: "America/Los_Angeles")
        let records = [early, late].map { AnalyticsEventRecord(event: $0, calendar: losAngeles) }
        #expect(records.map(\.day) == [day("2026-11-20"), day("2026-11-21")])
        #expect(records.map(\.hour) == [19, 12])
        #expect(StreakCalculator.currentStreakLength(activeDays: Set(records.map(\.day)), today: today) == 2)
    }
}
