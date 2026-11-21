import Foundation
import Testing
import LumenFoundation
import LumenOrganization

@Suite("QuickCaptureParser")
struct QuickCaptureParserTests {
    // Saturday 21 November 2026.
    let today = CalendarDate(year: 2026, month: 11, day: 21) ?? CalendarDate(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian))

    func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDate? { CalendarDate(year: y, month: m, day: d) }

    @Test("plain text stays a title")
    func plain() {
        let result = QuickCaptureParser.parse("Buy oat milk", today: today)
        #expect(result.title == "Buy oat milk")
        #expect(result.dueDate == nil)
        #expect(result.priority == .none)
        #expect(result.recognized.isEmpty)
    }

    @Test("dates, times, priority, tags and project in one line")
    func full() {
        let result = QuickCaptureParser.parse("Call Sam tomorrow at 5pm !high #Family +home_admin", today: today)
        #expect(result.title == "Call Sam")
        #expect(result.dueDate == day(2026, 11, 22))
        #expect(result.dueTime == TimeOfDay(hour: 17, minute: 0))
        #expect(result.priority == .high)
        #expect(result.tags == ["family"])
        #expect(result.projectName == "home admin")
        #expect(result.recognized == ["tomorrow", "at 5pm", "!high", "#Family", "+home_admin"])
    }

    @Test("weekday names mean the next such day after today")
    func weekdays() {
        #expect(QuickCaptureParser.parse("Review on friday", today: today).dueDate == day(2026, 11, 27))
        #expect(QuickCaptureParser.parse("Review sat", today: today).dueDate == day(2026, 11, 28))
        #expect(QuickCaptureParser.parse("Review next monday", today: today).dueDate == day(2026, 11, 23))
        #expect(QuickCaptureParser.parse("Plan next week", today: today).dueDate == day(2026, 11, 23))
        #expect(QuickCaptureParser.parse("Budget next month", today: today).dueDate == day(2026, 12, 1))
    }

    @Test("relative and absolute dates")
    func dates() {
        #expect(QuickCaptureParser.parse("Ship in 3 days", today: today).dueDate == day(2026, 11, 24))
        #expect(QuickCaptureParser.parse("Ship in a week", today: today).dueDate == day(2026, 11, 28))
        #expect(QuickCaptureParser.parse("Renew in 3 months", today: today).dueDate == day(2027, 2, 21))
        #expect(QuickCaptureParser.parse("Taxes 2027-04-15", today: today).dueDate == day(2027, 4, 15))
        #expect(QuickCaptureParser.parse("Party dec 31", today: today).dueDate == day(2026, 12, 31))
        #expect(QuickCaptureParser.parse("Party 1st jan", today: today).dueDate == day(2027, 1, 1))
        // A date already past this year rolls to next year.
        #expect(QuickCaptureParser.parse("Anniversary march 3rd", today: today).dueDate == day(2027, 3, 3))
        let tonight = QuickCaptureParser.parse("Read tonight", today: today)
        #expect(tonight.dueDate == today)
        #expect(tonight.dueTime == TimeOfDay(hour: 20, minute: 0))
    }

    @Test("times in several notations")
    func times() {
        #expect(QuickCaptureParser.parse("Standup 9:30am", today: today).dueTime == TimeOfDay(hour: 9, minute: 30))
        #expect(QuickCaptureParser.parse("Standup 17:45", today: today).dueTime == TimeOfDay(hour: 17, minute: 45))
        #expect(QuickCaptureParser.parse("Lunch at noon", today: today).dueTime == TimeOfDay(hour: 12, minute: 0))
        #expect(QuickCaptureParser.parse("Call at 8", today: today).dueTime == TimeOfDay(hour: 8, minute: 0))
        #expect(QuickCaptureParser.parse("Midnight 12am deploy", today: today).dueTime == TimeOfDay(hour: 0, minute: 0))
        // A bare number without "at" is part of the title.
        let bare = QuickCaptureParser.parse("Buy 3 apples", today: today)
        #expect(bare.dueTime == nil)
        #expect(bare.title == "Buy 3 apples")
        #expect(QuickCaptureParser.parse("Call 13pm", today: today).dueTime == nil)
    }

    @Test("repetition phrases and default due date")
    func repetition() {
        let daily = QuickCaptureParser.parse("Stretch every day", today: today)
        #expect(daily.recurrence == .daily)
        #expect(daily.dueDate == today)
        #expect(daily.title == "Stretch")

        let weekly = QuickCaptureParser.parse("Team sync every mon and thu at 10", today: today)
        #expect(weekly.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [.monday, .thursday]))
        #expect(weekly.dueDate == day(2026, 11, 23))
        #expect(weekly.dueTime == TimeOfDay(hour: 10, minute: 0))
        #expect(weekly.title == "Team sync")

        #expect(QuickCaptureParser.parse("Water plants every 2 weeks", today: today).recurrence == RecurrenceRule(frequency: .weekly, interval: 2))
        #expect(QuickCaptureParser.parse("Invoice monthly", today: today).recurrence == .monthly)
        #expect(QuickCaptureParser.parse("Standup every weekday", today: today).recurrence == .weekdaysOnly)
    }

    @Test("priority notations and invalid markers")
    func priority() {
        #expect(QuickCaptureParser.parse("Fix !4", today: today).priority == .urgent)
        #expect(QuickCaptureParser.parse("Fix !low", today: today).priority == .low)
        let invalid = QuickCaptureParser.parse("Wow! !great", today: today)
        #expect(invalid.priority == .none)
        #expect(invalid.title == "Wow! !great")
    }

    @Test("a line made only of syntax keeps its text as the title")
    func onlySyntax() {
        let result = QuickCaptureParser.parse("tomorrow !high", today: today)
        #expect(result.title == "tomorrow !high")
        #expect(result.dueDate == day(2026, 11, 22))
    }
}
