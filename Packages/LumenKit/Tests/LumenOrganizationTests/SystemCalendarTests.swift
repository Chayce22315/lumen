import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenTestSupport

/// A writable system calendar store held in memory.
actor RecordingSystemCalendar: ExternalCalendarSource {
    private(set) var access: ExternalCalendarAccess
    private let grantsOnRequest: Bool
    private let stored: [ExternalCalendar]
    private(set) var events: [String: ExternalEventRecord] = [:]
    private(set) var requestCount = 0
    private var nextNumber = 1

    static let home = ExternalCalendar(id: "cal-home", title: "Home", sourceName: "iCloud", isWritable: true)
    static let holidays = ExternalCalendar(id: "cal-holidays", title: "Holidays", sourceName: "Subscribed", isWritable: false)

    init(access: ExternalCalendarAccess = .granted, grantsOnRequest: Bool = true, calendars: [ExternalCalendar] = [home, holidays]) {
        self.access = access
        self.grantsOnRequest = grantsOnRequest
        self.stored = calendars
    }

    func isAuthorized() async -> Bool { access == .granted }
    func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence] { [] }
    func authorization() async -> ExternalCalendarAccess { access }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        access = grantsOnRequest ? .granted : .denied
        return access == .granted
    }

    func calendars() async throws -> [ExternalCalendar] { stored }
    func event(identifier: String) async throws -> ExternalEventRecord? { events[identifier] }

    func save(_ event: ExternalEventRecord) async throws -> String {
        var record = event
        let identifier: String
        if let existing = event.identifier {
            guard let previous = events[existing] else { throw OrganizationError.systemEventNotFound }
            identifier = existing
            if !event.replacesRecurrence { record.recurrence = previous.recurrence }
        } else {
            identifier = "evt-\(nextNumber)"
            nextNumber += 1
        }
        record.identifier = identifier
        events[identifier] = record
        return identifier
    }

    func deleteEvent(identifier: String) async throws {
        guard events.removeValue(forKey: identifier) != nil else { throw OrganizationError.systemEventNotFound }
    }

    func seed(_ record: ExternalEventRecord) {
        if let identifier = record.identifier { events[identifier] = record }
    }
}

@Suite("System calendar recurrence mapping")
struct ExternalRecurrenceMappingTests {
    let calendar = Calendar.testUTC
    /// A Wednesday.
    let anchor = makeDay(2026, 11, 18)

    @Test("weekly rules name their days; an empty set means the anchor's weekday")
    func weekly() {
        let plain = ExternalRecurrenceMapping.outbound(.weekly, anchor: anchor, calendar: calendar)
        #expect(plain.recurrence.frequency == .weekly)
        #expect(plain.recurrence.daysOfWeek == [ExternalRecurrence.DayOfWeek(weekday: .wednesday)])
        #expect(plain.notes.isEmpty)

        let fortnightly = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.saturday, .sunday])
        let mapped = ExternalRecurrenceMapping.outbound(fortnightly, anchor: anchor, calendar: calendar)
        #expect(mapped.recurrence.interval == 2)
        #expect(mapped.recurrence.daysOfWeek.map(\.weekday) == [.saturday, .sunday])
        #expect(mapped.notes.count == 1) // week start may differ
    }

    @Test("monthly patterns map to days of the month or numbered weekdays, with notes where months are skipped")
    func monthly() {
        let thirtyFirst = ExternalRecurrenceMapping.outbound(RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(31)), anchor: anchor, calendar: calendar)
        #expect(thirtyFirst.recurrence.daysOfMonth == [31])
        #expect(thirtyFirst.notes.first?.contains("skips") == true)

        let fifteenth = ExternalRecurrenceMapping.outbound(RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(15)), anchor: anchor, calendar: calendar)
        #expect(fifteenth.recurrence.daysOfMonth == [15])
        #expect(fifteenth.notes.isEmpty)

        let last = ExternalRecurrenceMapping.outbound(RecurrenceRule(frequency: .monthly, monthlyPattern: .lastDayOfMonth), anchor: anchor, calendar: calendar)
        #expect(last.recurrence.daysOfMonth == [-1])

        let lastFriday = ExternalRecurrenceMapping.outbound(
            RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: -1, weekday: .friday)), anchor: anchor, calendar: calendar)
        #expect(lastFriday.recurrence.daysOfWeek == [ExternalRecurrence.DayOfWeek(weekday: .friday, week: -1)])
        #expect(lastFriday.recurrence.daysOfMonth.isEmpty)

        let implicit = ExternalRecurrenceMapping.outbound(.monthly, anchor: anchor, calendar: calendar)
        #expect(implicit.recurrence.daysOfMonth == [18])
    }

    @Test("a yearly rule on February 29 is flagged; end dates include the whole last day")
    func yearlyAndEnds() throws {
        let leap = ExternalRecurrenceMapping.outbound(.yearly, anchor: makeDay(2028, 2, 29), calendar: calendar)
        #expect(leap.notes.count == 1)

        let until = ExternalRecurrenceMapping.outbound(RecurrenceRule(frequency: .daily, end: .onDate(makeDay(2026, 12, 24))), anchor: anchor, calendar: calendar)
        guard case .until(let date) = until.recurrence.end else {
            Issue.record("expected an end date")
            return
        }
        #expect(CalendarDate(date, calendar: calendar) == makeDay(2026, 12, 24))
        #expect(CalendarDate(date.addingTimeInterval(1), calendar: calendar) == makeDay(2026, 12, 25))

        let count = ExternalRecurrenceMapping.outbound(RecurrenceRule(frequency: .daily, end: .afterOccurrences(5)), anchor: anchor, calendar: calendar)
        #expect(count.recurrence.end == .count(5))
    }

    @Test("every rule Lumen can express survives the round trip")
    func roundTrip() {
        let rules: [RecurrenceRule] = [
            .daily,
            RecurrenceRule(frequency: .daily, interval: 3, end: .afterOccurrences(10)),
            RecurrenceRule(frequency: .weekly, weekdays: Weekday.weekdays),
            RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.monday, .thursday], end: .onDate(makeDay(2027, 3, 1))),
            RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(15)),
            RecurrenceRule(frequency: .monthly, interval: 2, monthlyPattern: .lastDayOfMonth),
            RecurrenceRule(frequency: .monthly, monthlyPattern: .weekdayOrdinal(ordinal: 2, weekday: .tuesday)),
            RecurrenceRule(frequency: .yearly, interval: 1),
        ]
        for rule in rules {
            let outbound = ExternalRecurrenceMapping.outbound(rule, anchor: anchor, calendar: calendar)
            let inbound = ExternalRecurrenceMapping.inbound(outbound.recurrence, calendar: calendar)
            #expect(inbound.note == nil)
            #expect(inbound.rule == rule, "\(rule.summary)")
        }
        // Implicit parts come back explicit.
        let weekly = ExternalRecurrenceMapping.inbound(ExternalRecurrenceMapping.outbound(.weekly, anchor: anchor, calendar: calendar).recurrence, calendar: calendar)
        #expect(weekly.rule == RecurrenceRule(frequency: .weekly, weekdays: [.wednesday]))
    }

    @Test("stored rules Lumen can't express are reported, not approximated")
    func unsupported() {
        let cases: [ExternalRecurrence] = [
            ExternalRecurrence(frequency: .monthly, daysOfMonth: [1, 15]),
            ExternalRecurrence(frequency: .monthly, daysOfWeek: [.init(weekday: .monday, week: 1)], setPositions: [1]),
            ExternalRecurrence(frequency: .weekly, daysOfWeek: [.init(weekday: .monday, week: 2)]),
            ExternalRecurrence(frequency: .daily, daysOfWeek: [.init(weekday: .monday)]),
            ExternalRecurrence(frequency: .yearly, daysOfWeek: [.init(weekday: .sunday, week: 1)], monthsOfYear: [5]),
            ExternalRecurrence(frequency: .yearly, weeksOfYear: [20]),
        ]
        for recurrence in cases {
            let inbound = ExternalRecurrenceMapping.inbound(recurrence, calendar: calendar)
            #expect(inbound.rule == nil)
            #expect(inbound.note?.contains("kept unless you change it") == true)
        }
    }
}

@Suite("System calendar events")
struct SystemCalendarServiceTests {
    private func timed(hour: Int, length: TimeInterval = 3_600) -> EventTiming {
        let start = makeDay(2026, 11, 23).startDate(in: .testUTC).addingTimeInterval(TimeInterval(hour) * 3_600)
        return .timed(start: start, end: start.addingTimeInterval(length), timeZoneIdentifier: "UTC")
    }

    @Test("without a system store nothing is offered and writes fail clearly")
    func unavailable() async throws {
        let harness = try await OrganizationHarness.make()
        #expect(!harness.calendars.supportsSystemCalendars)
        #expect(await harness.calendars.systemCalendarAccess() == nil)
        #expect(try await harness.calendars.writableSystemCalendars().isEmpty)
        await #expect(throws: OrganizationError.systemCalendarUnavailable) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: "Dentist", timing: timed(hour: 9)), toCalendar: "cal-home")
        }
    }

    @Test("access is requested once, only when undecided; denied access offers no calendars")
    func access() async throws {
        let store = RecordingSystemCalendar(access: .notDetermined)
        let harness = try await OrganizationHarness.make(external: store)
        #expect(await harness.calendars.systemCalendarAccess() == .notDetermined)
        #expect(try await harness.calendars.writableSystemCalendars().isEmpty)
        #expect(try await harness.calendars.requestSystemCalendarAccess() == .granted)
        #expect(try await harness.calendars.requestSystemCalendarAccess() == .granted)
        #expect(await store.requestCount == 1)
        #expect(try await harness.calendars.writableSystemCalendars().map(\.id) == ["cal-home"])

        let refused = RecordingSystemCalendar(access: .notDetermined, grantsOnRequest: false)
        let denied = try await OrganizationHarness.make(external: refused)
        #expect(try await denied.calendars.requestSystemCalendarAccess() == .denied)
        #expect(try await denied.calendars.writableSystemCalendars().isEmpty)
        await #expect(throws: OrganizationError.systemCalendarAccessDenied) {
            try await denied.calendars.saveSystemEvent(EventDraft(title: "Dentist", timing: timed(hour: 9)), toCalendar: "cal-home")
        }
    }

    @Test("an event is validated, written with mapped recurrence and alerts, and announced")
    func create() async throws {
        let store = RecordingSystemCalendar()
        let harness = try await OrganizationHarness.make(external: store)
        let recorder = EventRecorder(bus: harness.environment.events)
        let draft = EventDraft(
            title: "  Team   sync ",
            location: "Room 4",
            timing: timed(hour: 10),
            recurrence: RecurrenceRule(frequency: .weekly, weekdays: [.monday]),
            reminderOffsets: [30, 10, 30]
        )
        let identifier = try await harness.calendars.saveSystemEvent(draft, toCalendar: "cal-home")
        let stored = try #require(await store.events[identifier])
        #expect(stored.title == "Team sync")
        #expect(stored.calendarID == "cal-home")
        #expect(stored.alertOffsets == [10, 30])
        #expect(stored.recurrence?.daysOfWeek == [ExternalRecurrence.DayOfWeek(weekday: .monday)])

        let events = await recorder.waitForEvents(1)
        #expect(events.first?.name == OrganizationEvent.systemEventSaved)
        #expect(events.first?.entity == SystemCalendarEventReference.reference(for: identifier))
        #expect(events.first?.attributes.isEmpty == true) // no titles on the bus

        let form = try await harness.calendars.systemEvent(identifier)
        #expect(form.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [.monday]))
        #expect(form.isRecurrenceEditable)
        #expect(form.isEditable)
        #expect(form.calendarTitle == "Home")
    }

    @Test("read-only and unknown calendars, and invalid drafts, are refused before writing")
    func refusals() async throws {
        let store = RecordingSystemCalendar()
        let harness = try await OrganizationHarness.make(external: store)
        await #expect(throws: OrganizationError.systemCalendarReadOnly) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: "Party", timing: timed(hour: 20)), toCalendar: "cal-holidays")
        }
        await #expect(throws: OrganizationError.systemCalendarNotFound) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: "Party", timing: timed(hour: 20)), toCalendar: "cal-gone")
        }
        await #expect(throws: ValidationError.self) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: " ", timing: timed(hour: 20)), toCalendar: "cal-home")
        }
        await #expect(throws: ValidationError.self) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: "Backwards", timing: timed(hour: 20, length: -60)), toCalendar: "cal-home")
        }
        #expect(await store.events.isEmpty)
    }

    @Test("a repeat rule Lumen can't show is reported and kept when saving other changes")
    func keepsUnsupportedRecurrence() async throws {
        let store = RecordingSystemCalendar()
        let odd = ExternalRecurrence(frequency: .monthly, daysOfMonth: [1, 15])
        await store.seed(ExternalEventRecord(identifier: "evt-odd", calendarID: "cal-home", title: "Pay day", timing: timed(hour: 8), recurrence: odd, alertOffsets: [0], fixedAlertCount: 1))
        let harness = try await OrganizationHarness.make(external: store)

        let form = try await harness.calendars.systemEvent("evt-odd")
        #expect(form.recurrence == nil)
        #expect(!form.isRecurrenceEditable)
        #expect(form.record.fixedAlertCount == 1)

        try await harness.calendars.saveSystemEvent(
            EventDraft(title: "Payday", timing: timed(hour: 9), reminderOffsets: [60]),
            toCalendar: "cal-home", identifier: "evt-odd", keepingRecurrence: true
        )
        let stored = try #require(await store.events["evt-odd"])
        #expect(stored.title == "Payday")
        #expect(stored.recurrence == odd)
        #expect(stored.alertOffsets == [60])
    }

    @Test("deleting removes the event and announces it; a missing event is reported")
    func delete() async throws {
        let store = RecordingSystemCalendar()
        let harness = try await OrganizationHarness.make(external: store)
        let identifier = try await harness.calendars.saveSystemEvent(EventDraft(title: "Lunch", timing: timed(hour: 12)), toCalendar: "cal-home")
        let recorder = EventRecorder(bus: harness.environment.events)
        try await harness.calendars.deleteSystemEvent(identifier)
        #expect(await store.events.isEmpty)
        #expect(await recorder.waitForEvents(1).first?.name == OrganizationEvent.systemEventDeleted)
        await #expect(throws: OrganizationError.systemEventNotFound) { try await harness.calendars.deleteSystemEvent(identifier) }
        await #expect(throws: OrganizationError.systemEventNotFound) { try await harness.calendars.systemEvent(identifier) }
    }

    @Test("read-only sources keep working and refuse writes")
    func readOnlySource() async throws {
        let harness = try await OrganizationHarness.make(external: FakeExternalCalendar())
        #expect(await harness.calendars.systemCalendarAccess() == .granted)
        #expect(try await harness.calendars.writableSystemCalendars().isEmpty)
        await #expect(throws: OrganizationError.systemCalendarNotFound) {
            try await harness.calendars.saveSystemEvent(EventDraft(title: "Lunch", timing: timed(hour: 12)), toCalendar: "cal-home")
        }
    }

    @Test("editor notes appear only where the system calendar repeats differently")
    func compatibilityNotes() async throws {
        let harness = try await OrganizationHarness.make(external: RecordingSystemCalendar())
        #expect(harness.calendars.systemCompatibilityNotes(for: nil, timing: timed(hour: 9)).isEmpty)
        #expect(harness.calendars.systemCompatibilityNotes(for: .daily, timing: timed(hour: 9)).isEmpty)
        let notes = harness.calendars.systemCompatibilityNotes(for: RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(30)), timing: timed(hour: 9))
        #expect(notes.count == 1)
    }

    @Test("system event references are stable per identifier")
    func references() {
        let first = SystemCalendarEventReference.reference(for: "ABC:123")
        #expect(first == SystemCalendarEventReference.reference(for: "ABC:123"))
        #expect(first != SystemCalendarEventReference.reference(for: "ABC:124"))
        #expect(first.kind == .systemCalendarEvent)
        #expect(first.id.uuidString.dropFirst(14).first == "8") // version 8
    }
}
