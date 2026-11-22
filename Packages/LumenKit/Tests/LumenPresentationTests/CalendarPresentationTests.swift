import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication
import LumenPresentation
import LumenTestSupport

/// A writable system calendar store held in memory.
actor MemorySystemCalendar: ExternalCalendarSource {
    private(set) var access: ExternalCalendarAccess
    private let grantsOnRequest: Bool
    private(set) var events: [String: ExternalEventRecord] = [:]
    private var nextNumber = 1

    static let home = ExternalCalendar(id: "cal-home", title: "Home", sourceName: "iCloud", isWritable: true)
    static let holidays = ExternalCalendar(id: "cal-holidays", title: "Holidays", sourceName: "Subscribed", isWritable: false)

    init(access: ExternalCalendarAccess = .granted, grantsOnRequest: Bool = true) {
        self.access = access
        self.grantsOnRequest = grantsOnRequest
    }

    func isAuthorized() async -> Bool { access == .granted }
    func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence] { [] }
    func authorization() async -> ExternalCalendarAccess { access }

    func requestAuthorization() async throws -> Bool {
        access = grantsOnRequest ? .granted : .denied
        return access == .granted
    }

    func calendars() async throws -> [ExternalCalendar] { [Self.home, Self.holidays] }
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

/// A started Lumen with a system calendar store and a chosen calendar (time zone).
func makeCalendarServices(external: (any ExternalCalendarSource)?, calendar: Calendar = .testUTC) async throws -> (LumenServices, LumenRuntime) {
    var platform = PlatformServices.ephemeral()
    platform.externalCalendar = external
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-calendar-\(UUID().uuidString)")
    let services = try await LumenBootstrap.make(
        configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
        platform: platform,
        timeSource: ManualTimeSource(),
        calendar: calendar
    )
    let runtime = LumenRuntime(services: services)
    await runtime.start()
    return (services, runtime)
}

private func day(_ year: Int, _ month: Int, _ day: Int) throws -> CalendarDate {
    try #require(CalendarDate(year: year, month: month, day: day))
}

@Suite("Month grid")
struct MonthGridTests {
    @Test("weeks start on Monday and pad the month with neighbouring days")
    func shape() throws {
        // November 2026 starts on a Sunday and ends on a Monday: six weeks.
        let november = MonthGrid(containing: try day(2026, 11, 21))
        #expect(november.weeks.count == 6)
        #expect(november.firstDay == (try day(2026, 10, 26)))
        #expect(november.lastDay == (try day(2026, 12, 6)))
        #expect(november.firstOfMonth == (try day(2026, 11, 1)))
        #expect(november.weeks.allSatisfy { $0.count == 7 && $0.first?.isoWeekday == 1 })
        #expect(!november.contains(try day(2026, 10, 31)))
        #expect(november.contains(try day(2026, 11, 30)))
        #expect(november.dayCount == 42)

        // February 2027 starts on a Monday and has 28 days: exactly four weeks, no padding.
        let february = MonthGrid(containing: try day(2027, 2, 14))
        #expect(february.weeks.count == 4)
        #expect(february.firstDay == (try day(2027, 2, 1)))
        #expect(february.lastDay == (try day(2027, 2, 28)))

        // October 2026: Thursday to Saturday, five weeks.
        #expect(MonthGrid(containing: try day(2026, 10, 1)).weeks.count == 5)
    }

    @Test("moving by months keeps the day of the month, clamped to shorter months")
    func addingMonths() throws {
        #expect(MonthGrid.day(try day(2027, 1, 31), addingMonths: 1) == (try day(2027, 2, 28)))
        #expect(MonthGrid.day(try day(2028, 1, 31), addingMonths: 1) == (try day(2028, 2, 29)))
        #expect(MonthGrid.day(try day(2026, 12, 15), addingMonths: 1) == (try day(2027, 1, 15)))
        #expect(MonthGrid.day(try day(2026, 1, 15), addingMonths: -1) == (try day(2025, 12, 15)))
        #expect(MonthGrid.day(try day(2026, 3, 31), addingMonths: -13) == (try day(2025, 2, 28)))
    }
}

@MainActor
@Suite("Calendar month view")
struct CalendarMonthViewTests {
    @Test("density counts events and tasks on the right local days across a DST change")
    func densityAcrossDST() async throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let (services, runtime) = try await makeCalendarServices(external: nil, calendar: berlin)
        let events = services.organization.calendars
        func local(_ dayOfMonth: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(berlin.date(from: DateComponents(year: 2026, month: 10, day: dayOfMonth, hour: hour, minute: minute)))
        }
        // Clocks go back on 25 October 2026 at 03:00. 00:30 that night is still 24 October in UTC.
        let early = try local(25, 0, 30)
        _ = try await events.createEvent(EventDraft(title: "Night train", timing: .timed(start: early, end: early.addingTimeInterval(3_600), timeZoneIdentifier: "Europe/Berlin")))
        let late = try local(26, 0, 15)
        _ = try await events.createEvent(EventDraft(title: "Late call", timing: .timed(start: late, end: late.addingTimeInterval(1_800), timeZoneIdentifier: "Europe/Berlin")))
        _ = try await events.createEvent(EventDraft(title: "Trip", timing: .allDay(start: try day(2026, 10, 24), end: try day(2026, 10, 26))))
        _ = try await services.organization.tasks.create(TaskDraft(title: "Pack", dueDate: try day(2026, 10, 25)))

        let calendar = CalendarViewModel(services: services, locale: posix)
        await calendar.start()
        await calendar.setMode(.month)
        await calendar.select(try day(2026, 10, 25))

        #expect(calendar.month.month == 10)
        #expect(calendar.monthTitle == "October 2026")
        #expect(calendar.density(on: try day(2026, 10, 23)).isEmpty)
        #expect(calendar.density(on: try day(2026, 10, 24)) == DayDensity(events: 1, tasks: 0))
        #expect(calendar.density(on: try day(2026, 10, 25)) == DayDensity(events: 2, tasks: 1))
        #expect(calendar.density(on: try day(2026, 10, 26)) == DayDensity(events: 2, tasks: 0))
        #expect(calendar.density(on: try day(2026, 10, 27)).isEmpty)
        #expect(calendar.accessibilityLabel(for: try day(2026, 10, 25)).hasSuffix(", 2 events, 1 task"))
        #expect(calendar.accessibilityLabel(for: try day(2026, 10, 27)).hasSuffix(", nothing scheduled"))
        // The agenda below the grid is the selected day.
        #expect(calendar.state.value?.map(\.day) == [try day(2026, 10, 25)])
        #expect(calendar.state.value?.first?.entryCount == 3)
        await runtime.shutdown()
    }

    @Test("months move with a clamped day; switching back to week shows seven days")
    func navigation() async throws {
        let (services, runtime) = try await makeServices()
        let calendar = CalendarViewModel(services: services, locale: posix)
        await calendar.start()
        await calendar.setMode(.month)
        #expect(calendar.month.month == 11) // today is 21 November 2026
        await calendar.select(try day(2026, 10, 31))
        #expect(calendar.month.month == 10)
        await calendar.moveMonth(by: 1)
        #expect(calendar.selectedDay == (try day(2026, 11, 30)))
        #expect(calendar.month.month == 11)
        // Selecting a padding day from the next month moves the grid there.
        await calendar.select(try day(2026, 12, 3))
        #expect(calendar.month.month == 12)

        await calendar.setMode(.week)
        #expect(calendar.state.value?.count == 7)
        await calendar.goToToday()
        #expect(calendar.isShowingToday)
        await runtime.shutdown()
    }
}

@MainActor
@Suite("Event editor and system calendars")
struct EventEditorSystemCalendarTests {
    private func setTime(_ editor: EventEditorViewModel, services: LumenServices) throws {
        let start = try day(2026, 11, 23).startDate(in: services.calendar).addingTimeInterval(9 * 3_600)
        editor.start = start
        editor.end = start.addingTimeInterval(3_600)
    }

    @Test("without a system store, only Lumen calendars are offered and saving works as before")
    func lumenOnly() async throws {
        let (services, runtime) = try await makeServices()
        let editor = EventEditorViewModel(services: services)
        await editor.load()
        #expect(editor.systemAccess == nil)
        #expect(!editor.offersSystemCalendars)
        #expect(!editor.canRequestSystemAccess)
        #expect(editor.systemAccessExplanation == nil)
        guard case .lumen = editor.destination else {
            Issue.record("a new event defaults to a Lumen calendar")
            return
        }
        editor.title = "Dentist"
        try setTime(editor, services: services)
        #expect(await editor.save())
        #expect(try await services.organization.calendars.allEvents().map(\.title) == ["Dentist"])
        await runtime.shutdown()
    }

    @Test("access is asked for from the editor; a system event is saved with notes shown first")
    func createInSystemCalendar() async throws {
        let store = MemorySystemCalendar(access: .notDetermined)
        let (services, runtime) = try await makeCalendarServices(external: store)
        let editor = EventEditorViewModel(services: services)
        await editor.load()
        #expect(editor.canRequestSystemAccess)
        #expect(!editor.offersSystemCalendars)
        await editor.requestSystemAccess()
        #expect(editor.systemAccess == .granted)
        #expect(editor.systemCalendars.map(\.id) == ["cal-home"]) // read-only calendars are not offered
        #expect(editor.offersSystemCalendars)

        editor.destination = .system("cal-home")
        editor.title = "Rent"
        try setTime(editor, services: services)
        editor.recurrence = RecurrenceRule(frequency: .monthly, monthlyPattern: .dayOfMonth(31))
        #expect(editor.compatibilityNotes.count == 1)
        #expect(await editor.save())
        let saved = await store.events.values.map(\.title)
        #expect(saved == ["Rent"])
        #expect(try await services.organization.calendars.allEvents().isEmpty) // nothing copied into Lumen
        await runtime.shutdown()
    }

    @Test("refused access explains why only Lumen calendars are listed")
    func denied() async throws {
        let (services, runtime) = try await makeCalendarServices(external: MemorySystemCalendar(access: .denied))
        let editor = EventEditorViewModel(services: services)
        await editor.load()
        #expect(!editor.canRequestSystemAccess)
        #expect(!editor.offersSystemCalendars)
        #expect(editor.systemAccessExplanation?.contains("Privacy & Security") == true)
        await runtime.shutdown()
    }

    @Test("editing a system event keeps a repeat rule Lumen can't show until the user replaces it")
    func editSystemEvent() async throws {
        let store = MemorySystemCalendar()
        let start = try day(2026, 11, 23).startDate(in: .testUTC).addingTimeInterval(8 * 3_600)
        let odd = ExternalRecurrence(frequency: .monthly, daysOfMonth: [1, 15])
        await store.seed(ExternalEventRecord(
            identifier: "evt-pay", calendarID: "cal-home", title: "Pay day",
            timing: .timed(start: start, end: start.addingTimeInterval(1_800), timeZoneIdentifier: "UTC"),
            recurrence: odd, alertOffsets: [15], fixedAlertCount: 2
        ))
        let (services, runtime) = try await makeCalendarServices(external: store)
        let editor = EventEditorViewModel(services: services, systemEventIdentifier: "evt-pay")
        await editor.load()
        #expect(editor.isExisting)
        #expect(editor.destination == .system("cal-home"))
        #expect(!editor.offersLumenCalendars)
        #expect(editor.showsStoredRecurrenceNote)
        #expect(editor.compatibilityNotes.isEmpty)
        #expect(editor.otherAlertCount == 2)
        #expect(editor.reminderOffsets == [15])
        #expect(editor.title == "Pay day")

        editor.title = "Payday"
        #expect(await editor.save())
        #expect(await store.events["evt-pay"]?.recurrence == odd)
        #expect(await store.events["evt-pay"]?.title == "Payday")

        editor.replaceStoredRecurrence()
        #expect(!editor.showsStoredRecurrenceNote)
        #expect(await editor.save())
        #expect(await store.events["evt-pay"]?.recurrence == nil)

        #expect(await editor.delete())
        #expect(await store.events.isEmpty)
        await runtime.shutdown()
    }

    @Test("events in read-only calendars can be viewed but not saved")
    func readOnly() async throws {
        let store = MemorySystemCalendar()
        let start = try day(2026, 12, 25).startDate(in: .testUTC)
        await store.seed(ExternalEventRecord(
            identifier: "evt-xmas", calendarID: "cal-holidays", title: "Christmas",
            timing: .allDay(start: try day(2026, 12, 25), end: try day(2026, 12, 25))
        ))
        let (services, runtime) = try await makeCalendarServices(external: store)
        let editor = EventEditorViewModel(services: services, systemEventIdentifier: "evt-xmas")
        await editor.load()
        #expect(editor.isReadOnly)
        #expect(editor.systemCalendarTitle == "Holidays")
        #expect(editor.isAllDay)
        #expect(editor.start == start)
        #expect(!editor.canSave)
        await runtime.shutdown()
    }
}
