import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// The Plan › Calendar screen: a week strip and the agenda from the selected day.
@MainActor
@Observable
public final class CalendarViewModel {
    public private(set) var selectedDay: CalendarDate
    public private(set) var state: LoadState<[AgendaDay]> = .idle
    public private(set) var calendars: [LumenCalendar] = []
    public let labels: DateLabels

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices, locale: Locale = .current) {
        self.services = services
        self.selectedDay = services.today
        self.labels = DateLabels(calendar: services.calendar, locale: locale)
    }

    /// Monday-to-Sunday days of the week containing the selected day.
    public var weekDays: [CalendarDate] {
        let monday = selectedDay.adding(days: -(selectedDay.isoWeekday - 1))
        return (0..<7).map { monday.adding(days: $0) }
    }

    public var today: CalendarDate { services.today }

    public var isShowingToday: Bool { selectedDay == services.today }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .calendarEvent, .calendar]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func select(_ day: CalendarDate) async {
        selectedDay = day
        await load()
    }

    public func moveWeek(by weeks: Int) async {
        await select(selectedDay.adding(days: 7 * weeks))
    }

    public func goToToday() async {
        await select(services.today)
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            calendars = try await services.organization.calendars.calendars()
            state = .loaded(try await services.organization.agenda.agenda(from: selectedDay, days: 7))
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public func toggleVisibility(of id: LumenCalendar.ID) async {
        guard let calendar = calendars.first(where: { $0.id == id }) else { return }
        do {
            _ = try await services.organization.calendars.updateCalendar(id, isVisible: !calendar.isVisible)
        } catch {
            services.errors.report(error, context: "Updating a calendar")
        }
    }
}

/// Creating or editing an event.
@MainActor
@Observable
public final class EventEditorViewModel {
    public let eventID: CalendarEvent.ID?
    public var title = ""
    public var location = ""
    public var notes = ""
    public var isAllDay = false
    public var start: Date
    public var end: Date
    public var recurrence: RecurrenceRule?
    public var reminderOffsets: [Int] = [10]
    public var calendarID: LumenCalendar.ID?
    public private(set) var calendars: [LumenCalendar] = []
    public private(set) var error: ErrorPresentation?
    public private(set) var isSaving = false

    private let services: LumenServices

    public init(services: LumenServices, eventID: CalendarEvent.ID? = nil, day: CalendarDate? = nil) {
        self.services = services
        self.eventID = eventID
        let calendar = services.calendar
        let now = services.timeSource.now()
        // New events start on the next full hour (on the chosen day) and last an hour.
        let base = day.map { TimeOfDay(now, calendar: calendar).date(on: $0, calendar: calendar) } ?? now
        let nextHour = calendar.nextDate(after: base, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? base
        self.start = nextHour
        self.end = nextHour.addingTimeInterval(3_600)
    }

    public func load() async {
        do {
            calendars = try await services.organization.calendars.calendars()
            if calendarID == nil { calendarID = calendars.first?.id }
            guard let eventID, let event = try await services.organization.calendars.event(eventID) else { return }
            title = event.title
            location = event.location
            notes = event.notes
            recurrence = event.recurrence
            reminderOffsets = event.reminderOffsets
            calendarID = event.calendarID
            switch event.timing {
            case .timed(let start, let end, _):
                isAllDay = false
                self.start = start
                self.end = end
            case .allDay(let first, let last):
                isAllDay = true
                start = first.startDate(in: services.calendar)
                end = last.startDate(in: services.calendar)
            }
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public var canSave: Bool { !isSaving && title.collapsingWhitespace.nonBlank != nil && end >= start }

    /// Saves and returns the event, or `nil` with `error` set.
    @discardableResult
    public func save() async -> CalendarEvent? {
        isSaving = true
        error = nil
        defer { isSaving = false }
        let calendar = services.calendar
        let timing: EventTiming = isAllDay
            ? .allDay(start: CalendarDate(start, calendar: calendar), end: CalendarDate(end, calendar: calendar))
            : .timed(start: start, end: end, timeZoneIdentifier: calendar.timeZone.identifier)
        let draft = EventDraft(
            calendarID: calendarID, title: title, notes: notes, location: location,
            timing: timing, recurrence: recurrence, reminderOffsets: reminderOffsets
        )
        do {
            if let eventID {
                return try await services.organization.calendars.updateEvent(eventID, draft)
            }
            return try await services.organization.calendars.createEvent(draft)
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }

    public func delete() async -> Bool {
        guard let eventID else { return false }
        do {
            try await services.organization.calendars.deleteEvent(eventID)
            return true
        } catch {
            self.error = ErrorPresentation.from(error)
            return false
        }
    }
}
