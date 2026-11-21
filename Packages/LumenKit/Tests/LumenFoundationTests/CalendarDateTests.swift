import Foundation
import Testing
import LumenFoundation
import LumenTestSupport

@Suite("CalendarDate")
struct CalendarDateTests {
    @Test("rejects impossible dates")
    func validation() {
        #expect(CalendarDate(year: 2026, month: 2, day: 29) == nil)
        #expect(CalendarDate(year: 2028, month: 2, day: 29) != nil)
        #expect(CalendarDate(year: 2026, month: 4, day: 31) == nil)
        #expect(CalendarDate(year: 2026, month: 13, day: 1) == nil)
        #expect(CalendarDate(year: 1900, month: 2, day: 29) == nil)
        #expect(CalendarDate(year: 2000, month: 2, day: 29) != nil)
    }

    @Test("day arithmetic crosses months, years and leap days")
    func arithmetic() throws {
        let start = try #require(CalendarDate(year: 2028, month: 2, day: 28))
        #expect(start.adding(days: 1) == CalendarDate(year: 2028, month: 2, day: 29))
        #expect(start.adding(days: 2) == CalendarDate(year: 2028, month: 3, day: 1))
        let newYearsEve = try #require(CalendarDate(year: 2026, month: 12, day: 31))
        #expect(newYearsEve.adding(days: 1) == CalendarDate(year: 2027, month: 1, day: 1))
        #expect(newYearsEve.adding(days: -365) == CalendarDate(year: 2025, month: 12, day: 31))
        #expect(newYearsEve.adding(days: 1).days(since: start) == -423)
    }

    @Test("ISO weekday matches the gregorian calendar")
    func weekday() throws {
        // 21 November 2026 is a Saturday.
        let saturday = try #require(CalendarDate(year: 2026, month: 11, day: 21))
        #expect(saturday.isoWeekday == 6)
        #expect(saturday.adding(days: 1).isoWeekday == 7)
        #expect(saturday.adding(days: 2).isoWeekday == 1)
        let calendar = Calendar.testUTC
        for offset in 0..<14 {
            let day = saturday.adding(days: offset)
            let gregorian = calendar.component(.weekday, from: day.startDate(in: calendar))
            // Calendar weekday: 1 = Sunday … 7 = Saturday.
            let iso = gregorian == 1 ? 7 : gregorian - 1
            #expect(day.isoWeekday == iso)
        }
    }

    @Test("round-trips through text and Codable")
    func coding() throws {
        let date = try #require(CalendarDate(year: 2026, month: 3, day: 7))
        #expect(date.description == "2026-03-07")
        #expect(CalendarDate("2026-03-07") == date)
        #expect(CalendarDate("2026-3-7") == nil)
        let data = try JSONEncoder().encode([date])
        #expect(try JSONDecoder().decode([CalendarDate].self, from: data) == [date])
    }

    @Test("conversion to and from instants respects the calendar's time zone")
    func instants() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 2026-11-21 20:00 UTC is already the 22nd in Tokyo.
        let instant = Date(timeIntervalSince1970: 1_795_291_200)
        #expect(CalendarDate(instant, calendar: .testUTC) == CalendarDate(year: 2026, month: 11, day: 21))
        #expect(CalendarDate(instant, calendar: tokyo) == CalendarDate(year: 2026, month: 11, day: 22))
        let day = try #require(CalendarDate(year: 2026, month: 11, day: 22))
        #expect(CalendarDate(day.startDate(in: tokyo), calendar: tokyo) == day)
    }
}
