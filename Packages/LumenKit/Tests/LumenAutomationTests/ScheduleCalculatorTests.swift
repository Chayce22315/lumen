import Foundation
import Testing
import LumenFoundation
import LumenAutomation
import LumenTestSupport

/// The reference instant is Saturday 21 November 2026, 09:00 UTC.
@Suite("ScheduleCalculator")
struct ScheduleCalculatorTests {
    let calendar = Calendar.testUTC
    let now = ManualTimeSource.referenceDate

    func schedule(_ rule: RecurrenceRule = .daily, anchor: CalendarDate? = nil, at hour: Int, _ minute: Int = 0) throws -> ScheduleTrigger {
        ScheduleTrigger(rule: rule, anchor: try anchor ?? day(2026, 11, 1), time: try time(hour, minute))
    }

    @Test("a time later today fires today; an earlier one tomorrow")
    func daily() throws {
        #expect(ScheduleCalculator.nextFireDate(for: try schedule(at: 9, 30), after: now, calendar: calendar) == (try utc(2026, 11, 21, 9, 30)))
        #expect(ScheduleCalculator.nextFireDate(for: try schedule(at: 8, 0), after: now, calendar: calendar) == (try utc(2026, 11, 22, 8, 0)))
    }

    @Test("the next fire date is strictly after the given instant")
    func strictlyAfter() throws {
        #expect(ScheduleCalculator.nextFireDate(for: try schedule(at: 9, 0), after: now, calendar: calendar) == (try utc(2026, 11, 22, 9, 0)))
    }

    @Test("weekday schedules skip the weekend")
    func weekdays() throws {
        let rule = RecurrenceRule.weekdaysOnly
        #expect(ScheduleCalculator.nextFireDate(for: try schedule(rule, at: 7, 0), after: now, calendar: calendar) == (try utc(2026, 11, 23, 7, 0)))
    }

    @Test("a future anchor is the first occurrence")
    func futureAnchor() throws {
        let trigger = try schedule(.weekly, anchor: day(2026, 12, 3), at: 18, 15)
        #expect(ScheduleCalculator.nextFireDate(for: trigger, after: now, calendar: calendar) == (try utc(2026, 12, 3, 18, 15)))
    }

    @Test("an ended series has no next fire date")
    func ended() throws {
        let trigger = try schedule(RecurrenceRule(frequency: .daily, end: .afterOccurrences(2)), anchor: day(2026, 11, 1), at: 9, 0)
        #expect(ScheduleCalculator.nextFireDate(for: trigger, after: now, calendar: calendar) == nil)
        let until = try schedule(RecurrenceRule(frequency: .daily, end: .onDate(day(2026, 11, 21))), at: 10, 0)
        #expect(ScheduleCalculator.nextFireDate(for: until, after: now, calendar: calendar) == (try utc(2026, 11, 21, 10, 0)))
        #expect(ScheduleCalculator.nextFireDate(for: until, after: try utc(2026, 11, 21, 10, 0), calendar: calendar) == nil)
    }

    @Test("monthly schedules clamp to short months")
    func monthlyClamp() throws {
        let trigger = try schedule(RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(31)), anchor: day(2026, 10, 31), at: 12, 0)
        #expect(ScheduleCalculator.nextFireDate(for: trigger, after: now, calendar: calendar) == (try utc(2026, 11, 30, 12, 0)))
    }

    @Test("wall-clock times follow the injected calendar's time zone")
    func timeZones() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // 09:00 UTC is 04:00 in New York; 09:00 New York (EST) is 14:00 UTC the same day.
        #expect(ScheduleCalculator.nextFireDate(for: try schedule(at: 9, 0), after: now, calendar: newYork) == (try utc(2026, 11, 21, 14, 0)))
    }

    @Test("fire dates in a range are listed in order")
    func range() throws {
        let dates = ScheduleCalculator.fireDates(for: try schedule(at: 9, 30), after: now, through: try utc(2026, 11, 24, 9, 30), calendar: calendar, limit: 10)
        #expect(dates == [try utc(2026, 11, 21, 9, 30), try utc(2026, 11, 22, 9, 30), try utc(2026, 11, 23, 9, 30), try utc(2026, 11, 24, 9, 30)])
        #expect(ScheduleCalculator.fireDates(for: try schedule(at: 9, 30), after: now, through: try utc(2026, 11, 24), calendar: calendar, limit: 2).count == 2)
    }

    @Test("a schedule that is not due yet keeps its fire date")
    func notDue() throws {
        let fire = try utc(2026, 11, 21, 9, 30)
        let decision = ScheduleCalculator.decision(for: try schedule(at: 9, 30), scheduledFireDate: fire, now: now, calendar: calendar)
        #expect(decision == ScheduleDecision(isDue: false, coalescedOccurrences: 0, nextFireDate: fire))
    }

    @Test("missed occurrences are coalesced into one firing and the next date is after now")
    func catchUp() throws {
        let trigger = try schedule(at: 9, 30)
        let later = try utc(2026, 11, 24, 10, 0)
        let decision = ScheduleCalculator.decision(for: trigger, scheduledFireDate: try utc(2026, 11, 21, 9, 30), now: later, calendar: calendar)
        #expect(decision.isDue)
        #expect(decision.coalescedOccurrences == 4)
        #expect(decision.nextFireDate == (try utc(2026, 11, 25, 9, 30)))
    }

    @Test("an unscheduled state computes the first fire date without firing")
    func firstSchedule() throws {
        let decision = ScheduleCalculator.decision(for: try schedule(at: 9, 30), scheduledFireDate: nil, now: now, calendar: calendar)
        #expect(!decision.isDue)
        #expect(decision.nextFireDate == (try utc(2026, 11, 21, 9, 30)))
    }
}
