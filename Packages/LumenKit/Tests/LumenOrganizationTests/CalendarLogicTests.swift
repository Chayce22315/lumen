import Foundation
import Testing
import LumenFoundation
import LumenOrganization
import LumenTestSupport

@Suite("Calendar logic")
struct CalendarLogicTests {
    let calendar = Calendar.testUTC
    let now = ManualTimeSource.referenceDate // Sat 21 Nov 2026 09:00 UTC

    func event(_ timing: EventTiming, recurrence: RecurrenceRule? = nil, reminders: [Int] = []) -> CalendarEvent {
        CalendarEvent(calendarID: LumenCalendar.ID(), title: "Event", timing: timing, recurrence: recurrence, reminderOffsets: reminders, createdAt: now, updatedAt: now)
    }

    @Test("a single timed event appears only when it overlaps the window")
    func single() {
        let e = event(.timed(start: now, end: now.addingTimeInterval(3_600), timeZoneIdentifier: "UTC"))
        #expect(EventOccurrenceExpander.occurrences(of: e, color: .blue, from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60), calendar: calendar).count == 1)
        #expect(EventOccurrenceExpander.occurrences(of: e, color: .blue, from: now.addingTimeInterval(3_600), to: now.addingTimeInterval(7_200), calendar: calendar).isEmpty)
    }

    @Test("weekly recurring events keep local wall time across DST")
    func dst() throws {
        // Every Monday 09:00 in New York, starting Monday 26 Oct 2026 (EDT, UTC-4). DST ends 1 Nov.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(TimeOfDay(hour: 9, minute: 0)).date(on: makeDay(2026, 10, 26), calendar: newYork)
        let e = event(.timed(start: start, end: start.addingTimeInterval(1_800), timeZoneIdentifier: "America/New_York"), recurrence: .weekly)
        let occurrences = EventOccurrenceExpander.occurrences(of: e, color: .blue, from: start, to: start.addingTimeInterval(15 * 86_400), calendar: newYork)
        #expect(occurrences.count == 3)
        let hours = occurrences.map { newYork.component(.hour, from: $0.start) }
        #expect(hours == [9, 9, 9])
        // The UTC hour shifts from 13:00 to 14:00 after DST ends.
        #expect(occurrences.map { calendar.component(.hour, from: $0.start) } == [13, 14, 14])
    }

    @Test("multi-day all-day events cover each day, recurring ones expand")
    func allDay() {
        let trip = event(.allDay(start: makeDay(2026, 11, 20), end: makeDay(2026, 11, 22)))
        let occurrences = EventOccurrenceExpander.occurrences(of: trip, color: .teal, from: now, to: now.addingTimeInterval(86_400), calendar: calendar)
        #expect(occurrences.count == 1)
        #expect(occurrences.first?.covers(makeDay(2026, 11, 22)) == true)
        #expect(occurrences.first?.covers(makeDay(2026, 11, 23)) == false)

        let birthday = event(.allDay(start: makeDay(2020, 11, 25), end: makeDay(2020, 11, 25)), recurrence: .yearly)
        let window = EventOccurrenceExpander.occurrences(of: birthday, color: .rose, from: now, to: now.addingTimeInterval(400 * 86_400), calendar: calendar)
        #expect(window.map(\.firstDay) == [makeDay(2026, 11, 25), makeDay(2027, 11, 25)])
    }

    @Test("agenda groups all-day, scheduled and anytime entries")
    func agenda() {
        let today = makeDay(2026, 11, 21)
        let meeting = EventOccurrenceExpander.occurrences(
            of: event(.timed(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200), timeZoneIdentifier: "UTC")),
            color: .blue, from: now, to: now.addingTimeInterval(86_400), calendar: calendar)
        let holiday = EventOccurrenceExpander.occurrences(
            of: event(.allDay(start: today, end: today)), color: .green, from: now, to: now.addingTimeInterval(86_400), calendar: calendar)
        let early = makeTask("early call", due: today, time: TimeOfDay(hour: 8, minute: 0))
        let anytime = makeTask("anytime", due: today)
        let overdue = makeTask("overdue", due: makeDay(2026, 11, 18))
        let days = AgendaBuilder.agenda(days: [today, today.adding(days: 1)], tasks: [early, anytime, overdue], occurrences: meeting + holiday, calendar: calendar, includeOverdueOnFirstDay: true)
        let first = days[0]
        #expect(first.allDay.count == 1)
        #expect(first.scheduled.map(\.id).first == "task:\(early.id.uuidString)")
        #expect(first.scheduled.count == 2)
        #expect(Set(first.anytime.map(\.id)) == ["task:\(anytime.id.uuidString)", "task:\(overdue.id.uuidString)"])
        #expect(days[1].isEmpty)
    }

    @Test("reminder planning for tasks and events")
    func reminders() {
        var task = makeTask("Call", due: makeDay(2026, 11, 21), time: TimeOfDay(hour: 15, minute: 0))
        task.reminder = .minutesBefore(30)
        let planned = ReminderPlanner.reminder(for: task, now: now, calendar: calendar)
        #expect(planned?.fireDate == now.addingTimeInterval(5.5 * 3_600))
        task.reminder = .atDue
        task.dueTime = nil
        #expect(ReminderPlanner.reminder(for: task, now: now, calendar: calendar) == nil) // 09:00 default has passed (not after now)
        task.status = .done
        task.reminder = .at(now.addingTimeInterval(60))
        #expect(ReminderPlanner.reminder(for: task, now: now, calendar: calendar) == nil)

        let e = event(.timed(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200), timeZoneIdentifier: "UTC"), reminders: [10, 120])
        let occurrences = EventOccurrenceExpander.occurrences(of: e, color: .blue, from: now, to: now.addingTimeInterval(86_400), calendar: calendar)
        let eventReminders = ReminderPlanner.reminders(for: occurrences, event: e, now: now, horizon: 86_400)
        #expect(eventReminders.map(\.fireDate) == [now.addingTimeInterval(3_000)]) // the 120-minute one is in the past
    }
}
