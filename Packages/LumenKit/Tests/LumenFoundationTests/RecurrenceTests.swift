import Foundation
import Testing
import LumenFoundation
import LumenTestSupport

@Suite("Recurrence")
struct RecurrenceTests {
    func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDate {
        guard let value = CalendarDate(year: y, month: m, day: d) else {
            Issue.record("invalid test date \(y)-\(m)-\(d)")
            return CalendarDate(Date(timeIntervalSince1970: 0), calendar: .testUTC)
        }
        return value
    }

    @Test("daily with interval")
    func daily() {
        let rule = RecurrenceRule(frequency: .daily, interval: 3)
        let result = RecurrenceCalculator.occurrences(of: rule, anchor: day(2026, 2, 26), limit: 4)
        #expect(result == [day(2026, 2, 26), day(2026, 3, 1), day(2026, 3, 4), day(2026, 3, 7)])
    }

    @Test("weekly on several weekdays starts at the anchor, not before it")
    func weeklyWeekdays() {
        // Anchor Wednesday 2026-11-18; Mondays are skipped in the anchor's week because they precede it.
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [.monday, .wednesday, .friday])
        let result = RecurrenceCalculator.occurrences(of: rule, anchor: day(2026, 11, 18), limit: 5)
        #expect(result == [day(2026, 11, 18), day(2026, 11, 20), day(2026, 11, 23), day(2026, 11, 25), day(2026, 11, 27)])
    }

    @Test("every other week on the anchor weekday")
    func biweekly() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 2)
        let result = RecurrenceCalculator.occurrences(of: rule, anchor: day(2026, 12, 25), limit: 3)
        #expect(result == [day(2026, 12, 25), day(2027, 1, 8), day(2027, 1, 22)])
    }

    @Test("monthly on the 31st clamps to short months")
    func monthlyClamp() {
        let result = RecurrenceCalculator.occurrences(of: .monthly, anchor: day(2026, 1, 31), limit: 4)
        #expect(result == [day(2026, 1, 31), day(2026, 2, 28), day(2026, 3, 31), day(2026, 4, 30)])
    }

    @Test("monthly on the last Friday and on the second Tuesday")
    func monthlyOrdinal() {
        let lastFriday = RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: -1, weekday: .friday))
        #expect(RecurrenceCalculator.occurrences(of: lastFriday, anchor: day(2026, 11, 1), limit: 3)
            == [day(2026, 11, 27), day(2026, 12, 25), day(2027, 1, 29)])
        let secondTuesday = RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: 2, weekday: .tuesday))
        #expect(RecurrenceCalculator.occurrences(of: secondTuesday, anchor: day(2026, 11, 1), limit: 2)
            == [day(2026, 11, 10), day(2026, 12, 8)])
    }

    @Test("a fifth weekday skips months that don't have one")
    func fifthWeekday() {
        let rule = RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: 5, weekday: .monday))
        // Mondays: Nov 2026 has 5 (30th), Dec 2026 has 4, Jan 2027 has 4, Feb 2027 has 4, Mar 2027 has 5 (29th).
        #expect(RecurrenceCalculator.occurrences(of: rule, anchor: day(2026, 11, 1), limit: 2) == [day(2026, 11, 30), day(2027, 3, 29)])
    }

    @Test("yearly on 29 February falls back to the 28th")
    func leapYearly() {
        let result = RecurrenceCalculator.occurrences(of: .yearly, anchor: day(2028, 2, 29), limit: 3)
        #expect(result == [day(2028, 2, 29), day(2029, 2, 28), day(2030, 2, 28)])
    }

    @Test("end conditions limit the series")
    func ends() {
        let counted = RecurrenceRule(frequency: .daily, end: .afterOccurrences(3))
        #expect(RecurrenceCalculator.occurrences(of: counted, anchor: day(2026, 1, 1), limit: 10).count == 3)
        // The count includes occurrences before `after`.
        #expect(RecurrenceCalculator.occurrences(of: counted, anchor: day(2026, 1, 1), after: day(2026, 1, 2), limit: 10) == [day(2026, 1, 3)])
        let until = RecurrenceRule(frequency: .weekly, end: .onDate(day(2026, 1, 15)))
        #expect(RecurrenceCalculator.occurrences(of: until, anchor: day(2026, 1, 1), limit: 10) == [day(2026, 1, 1), day(2026, 1, 8), day(2026, 1, 15)])
        #expect(RecurrenceCalculator.nextOccurrence(of: until, anchor: day(2026, 1, 1), after: day(2026, 1, 15)) == nil)
    }

    @Test("next occurrence and membership")
    func nextAndMembership() {
        let rule = RecurrenceRule.weekdaysOnly
        let friday = day(2026, 11, 20)
        #expect(RecurrenceCalculator.nextOccurrence(of: rule, anchor: day(2026, 11, 2), after: friday) == day(2026, 11, 23))
        #expect(RecurrenceCalculator.occurs(rule, anchor: day(2026, 11, 2), on: day(2026, 11, 19)))
        #expect(!RecurrenceCalculator.occurs(rule, anchor: day(2026, 11, 2), on: day(2026, 11, 21)))
        #expect(!RecurrenceCalculator.occurs(rule, anchor: day(2026, 11, 2), on: day(2026, 10, 30)))
    }

    @Test("summaries read naturally")
    func summaries() {
        #expect(RecurrenceRule.weekdaysOnly.summary == "Every weekday")
        #expect(RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.wednesday, .monday]).summary == "Every 2 weeks on Mon, Wed")
        #expect(RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: -1, weekday: .friday), end: .afterOccurrences(6)).summary
            == "Every month on the last Fri 6 times")
    }

    @Test("time of day resolves on a calendar day")
    func timeOfDay() throws {
        let time = try #require(TimeOfDay(hour: 9, minute: 30))
        #expect(time.description == "09:30")
        #expect(TimeOfDay(hour: 24, minute: 0) == nil)
        let instant = time.date(on: day(2026, 11, 21), calendar: .testUTC)
        #expect(instant == ManualTimeSource.referenceDate.addingTimeInterval(1_800))
    }
}
