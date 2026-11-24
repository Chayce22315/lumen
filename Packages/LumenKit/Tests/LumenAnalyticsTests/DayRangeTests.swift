import Foundation
import Testing
import LumenFoundation
import LumenAnalytics
import LumenTestSupport

@Suite("DayRange")
struct DayRangeTests {
    @Test("bounds are ordered, so a range always holds at least one day")
    func ordering() {
        let range = DayRange(start: day("2026-11-22"), end: day("2026-11-16"))
        #expect(range.start == day("2026-11-16"))
        #expect(range.end == day("2026-11-22"))
        #expect(range.dayCount == 7)
        #expect(range.contains(day("2026-11-16")) && range.contains(day("2026-11-22")))
        #expect(!range.contains(day("2026-11-15")) && !range.contains(day("2026-11-23")))
        #expect(DayRange(day: day("2026-11-21")).dayCount == 1)
    }

    @Test("days run across month and year boundaries")
    func daysAcrossBoundaries() {
        let range = DayRange(start: day("2026-12-30"), end: day("2027-01-02"))
        #expect(range.days == [day("2026-12-30"), day("2026-12-31"), day("2027-01-01"), day("2027-01-02")])
        #expect(DayRange(start: day("2028-02-27"), end: day("2028-03-01")).dayCount == 4) // leap year
        #expect(DayRange(start: day("2027-02-27"), end: day("2027-03-01")).dayCount == 3)
    }

    @Test("last N days end on the given day and never shrink below one day")
    func lastDays() {
        #expect(DayRange.lastDays(7, endingOn: day("2026-11-21")) == DayRange(start: day("2026-11-15"), end: day("2026-11-21")))
        #expect(DayRange.lastDays(3, endingOn: day("2026-03-01")) == DayRange(start: day("2026-02-27"), end: day("2026-03-01")))
        #expect(DayRange.lastDays(0, endingOn: day("2026-11-21")) == DayRange(day: day("2026-11-21")))
        #expect(DayRange.lastDays(-4, endingOn: day("2026-11-21")).dayCount == 1)
    }

    @Test("weeks start on the calendar's first weekday")
    func weeks() {
        let saturday = day("2026-11-21")
        let sunday = day("2026-11-22")
        #expect(DayRange.week(containing: saturday, calendar: .testUTC) == DayRange(start: day("2026-11-16"), end: day("2026-11-22")))
        #expect(DayRange.week(containing: sunday, calendar: .testUTC) == DayRange(start: day("2026-11-16"), end: day("2026-11-22")))
        #expect(DayRange.week(containing: saturday, calendar: Fixture.sundayFirstUTC) == DayRange(start: day("2026-11-15"), end: day("2026-11-21")))
        #expect(DayRange.week(containing: sunday, calendar: Fixture.sundayFirstUTC) == DayRange(start: day("2026-11-22"), end: day("2026-11-28")))

        var saturdayFirst = Calendar.testUTC
        saturdayFirst.firstWeekday = 7
        #expect(DayRange.week(containing: day("2026-11-20"), calendar: saturdayFirst).start == day("2026-11-14"))
    }

    @Test("this week runs from the start of the week through today")
    func thisWeek() {
        #expect(DayRange.thisWeek(today: day("2026-11-21"), calendar: .testUTC) == DayRange(start: day("2026-11-16"), end: day("2026-11-21")))
        #expect(DayRange.thisWeek(today: day("2026-11-21"), calendar: Fixture.sundayFirstUTC) == DayRange(start: day("2026-11-15"), end: day("2026-11-21")))
        #expect(DayRange.thisWeek(today: day("2026-11-16"), calendar: .testUTC) == DayRange(day: day("2026-11-16")))
        // A week that straddles the new year.
        #expect(DayRange.thisWeek(today: day("2027-01-01"), calendar: .testUTC).start == day("2026-12-28"))
    }

    @Test("the previous period has the same length and ends the day before")
    func previousPeriod() {
        let week = DayRange(start: day("2026-11-16"), end: day("2026-11-22"))
        #expect(week.previousPeriod == DayRange(start: day("2026-11-09"), end: day("2026-11-15")))
        let march = DayRange(start: day("2026-03-01"), end: day("2026-03-31"))
        #expect(march.previousPeriod == DayRange(start: day("2026-01-29"), end: day("2026-02-28")))
        #expect(DayRange(day: day("2027-01-01")).previousPeriod == DayRange(day: day("2026-12-31")))
        #expect(week.shifted(byDays: 7) == DayRange(start: day("2026-11-23"), end: day("2026-11-29")))
    }

    @Test("months cover every day, including leap days")
    func months() {
        #expect(DayRange.month(containing: day("2028-02-10")) == DayRange(start: day("2028-02-01"), end: day("2028-02-29")))
        #expect(DayRange.month(containing: day("2026-12-31")) == DayRange(start: day("2026-12-01"), end: day("2026-12-31")))
        #expect(DayRange.thisMonth(today: day("2026-11-21")) == DayRange(start: day("2026-11-01"), end: day("2026-11-21")))
    }

    @Test("intersections are the shared days or nil")
    func intersection() {
        let a = DayRange(start: day("2026-11-01"), end: day("2026-11-10"))
        let b = DayRange(start: day("2026-11-08"), end: day("2026-11-20"))
        #expect(a.intersection(b) == DayRange(start: day("2026-11-08"), end: day("2026-11-10")))
        #expect(a.intersection(DayRange(day: day("2026-11-11"))) == nil)
    }

    @Test("decoding keeps the ordering invariant")
    func codable() throws {
        let decoded = try JSONCoding.decode(DayRange.self, from: #"{"start":"2026-11-22","end":"2026-11-16"}"#)
        #expect(decoded == DayRange(start: day("2026-11-16"), end: day("2026-11-22")))
        let roundTrip = try JSONCoding.decode(DayRange.self, from: try JSONCoding.encodeString(decoded))
        #expect(roundTrip == decoded)
        #expect(decoded.description == "2026-11-16…2026-11-22")
    }
}
