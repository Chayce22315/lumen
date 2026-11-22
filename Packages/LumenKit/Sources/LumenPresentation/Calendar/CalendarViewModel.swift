import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenApplication

/// Whether the Calendar screen shows a week strip or a month grid.
public enum CalendarMode: String, Sendable, Hashable, CaseIterable {
    case week
    case month

    public var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

/// The Plan › Calendar screen: a week strip over a seven-day agenda, or a month grid over the
/// selected day's agenda.
@MainActor
@Observable
public final class CalendarViewModel {
    public private(set) var selectedDay: CalendarDate
    public private(set) var mode: CalendarMode = .week
    /// Week mode: seven days from the selected day. Month mode: the selected day only.
    public private(set) var state: LoadState<[AgendaDay]> = .idle
    public private(set) var calendars: [LumenCalendar] = []
    public private(set) var month: MonthGrid
    /// Events and tasks per day of `month`; empty until the month has loaded.
    public private(set) var monthDensity: [CalendarDate: DayDensity] = [:]
    public let labels: DateLabels

    private let services: LumenServices
    private let locale: Locale
    private let observation = ObservationHandle()

    public init(services: LumenServices, locale: Locale = .current) {
        self.services = services
        self.locale = locale
        self.selectedDay = services.today
        self.month = MonthGrid(containing: services.today)
        self.labels = DateLabels(calendar: services.calendar, locale: locale)
    }

    /// Monday-to-Sunday days of the week containing the selected day.
    public var weekDays: [CalendarDate] {
        let monday = selectedDay.adding(days: -(selectedDay.isoWeekday - 1))
        return (0..<7).map { monday.adding(days: $0) }
    }

    public var today: CalendarDate { services.today }

    public var isShowingToday: Bool { selectedDay == services.today }

    /// "November 2026".
    public var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = services.calendar
        formatter.timeZone = services.calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: month.firstOfMonth.startDate(in: services.calendar))
    }

    public func density(on day: CalendarDate) -> DayDensity {
        monthDensity[day] ?? .empty
    }

    /// "Today, 2 events, 1 task" / "25 Oct, nothing scheduled" for VoiceOver.
    public func accessibilityLabel(for day: CalendarDate) -> String {
        let density = density(on: day)
        var parts = [labels.dayLabel(day, today: today)]
        if density.events > 0 { parts.append(density.events == 1 ? "1 event" : "\(density.events) events") }
        if density.tasks > 0 { parts.append(density.tasks == 1 ? "1 task" : "\(density.tasks) tasks") }
        if density.isEmpty { parts.append("nothing scheduled") }
        return parts.joined(separator: ", ")
    }

    public func start() async {
        await load()
        services.events.observe(
            EventFilter(modules: ["organization", "sync"], entityKinds: [.task, .calendarEvent, .calendar, .systemCalendarEvent]),
            into: observation
        ) { [weak self] in
            await self?.load()
        }
    }

    public func setMode(_ mode: CalendarMode) async {
        guard mode != self.mode else { return }
        self.mode = mode
        state = .loading
        await load()
    }

    public func select(_ day: CalendarDate) async {
        selectedDay = day
        await load()
    }

    public func moveWeek(by weeks: Int) async {
        await select(selectedDay.adding(days: 7 * weeks))
    }

    /// The same day of the month in another month (clamped to its length).
    public func moveMonth(by months: Int) async {
        await select(MonthGrid.day(selectedDay, addingMonths: months))
    }

    public func goToToday() async {
        await select(services.today)
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            calendars = try await services.organization.calendars.calendars()
            let agenda = services.organization.agenda
            switch mode {
            case .week:
                state = .loaded(try await agenda.agenda(from: selectedDay, days: 7))
            case .month:
                let grid = MonthGrid(containing: selectedDay)
                // Overdue work is carried into today's agenda only when the agenda starts today,
                // so the selected day is read on its own, the grid as a whole for the dots.
                async let selected = agenda.agenda(from: selectedDay, days: 1)
                let covered = try await agenda.agenda(from: grid.firstDay, days: grid.dayCount)
                month = grid
                monthDensity = MonthGrid.density(of: covered)
                state = .loaded(try await selected)
            }
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

/// Which calendar an event is saved in: one of Lumen's or one of the system's.
public enum EventCalendarChoice: Sendable, Hashable {
    case lumen(LumenCalendar.ID)
    case system(String)
}

/// Creating or editing an event in a Lumen calendar or a system calendar.
@MainActor
@Observable
public final class EventEditorViewModel {
    /// A Lumen event being edited.
    public let eventID: CalendarEvent.ID?
    /// A system-calendar event being edited.
    public let systemEventIdentifier: String?
    public var title = ""
    public var location = ""
    public var notes = ""
    public var isAllDay = false
    public var start: Date
    public var end: Date
    public var recurrence: RecurrenceRule? {
        didSet { recurrenceChanged = true }
    }
    public var reminderOffsets: [Int] = [10]
    public var destination: EventCalendarChoice?
    public private(set) var calendars: [LumenCalendar] = []
    /// Writable system calendars; empty without access.
    public private(set) var systemCalendars: [ExternalCalendar] = []
    /// `nil` when this device has no system calendar store.
    public private(set) var systemAccess: ExternalCalendarAccess?
    /// The event's calendar can't be changed (a subscription, for example).
    public private(set) var isReadOnly = false
    /// Name of the system calendar a system event belongs to.
    public private(set) var systemCalendarTitle: String?
    /// Why the stored repeat rule of a system event can't be edited here.
    public private(set) var storedRecurrenceNote: String?
    /// Alerts on a system event that Lumen can't edit; they are kept when saving.
    public private(set) var otherAlertCount = 0
    public private(set) var error: ErrorPresentation?
    public private(set) var isSaving = false

    private var recurrenceChanged = false
    private let services: LumenServices

    public init(services: LumenServices, eventID: CalendarEvent.ID? = nil, systemEventIdentifier: String? = nil, day: CalendarDate? = nil) {
        self.services = services
        self.eventID = eventID
        self.systemEventIdentifier = systemEventIdentifier
        let calendar = services.calendar
        let now = services.timeSource.now()
        // New events start on the next full hour (on the chosen day) and last an hour.
        let base = day.map { TimeOfDay(now, calendar: calendar).date(on: $0, calendar: calendar) } ?? now
        let nextHour = calendar.nextDate(after: base, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? base
        self.start = nextHour
        self.end = nextHour.addingTimeInterval(3_600)
    }

    public var isExisting: Bool { eventID != nil || systemEventIdentifier != nil }

    public var isSystemEvent: Bool {
        if case .system = destination { return true }
        return false
    }

    /// Lumen calendars are offered unless a system event is being edited.
    public var offersLumenCalendars: Bool { systemEventIdentifier == nil }

    /// System calendars are offered for new events (and for editing a system event).
    public var offersSystemCalendars: Bool { eventID == nil && !systemCalendars.isEmpty }

    /// A new event can ask for calendar access when it has not been decided yet.
    public var canRequestSystemAccess: Bool { !isExisting && systemAccess == .notDetermined }

    /// Shown when access was refused, so the user knows why only Lumen calendars are listed.
    public var systemAccessExplanation: String? {
        guard !isExisting, systemAccess == .denied else { return nil }
        return "Lumen can't add events to your other calendars without access. You can allow full access in Settings › Privacy & Security › Calendars."
    }

    /// Whether the editor shows the stored-rule note instead of the repeat picker.
    public var showsStoredRecurrenceNote: Bool { storedRecurrenceNote != nil && !recurrenceChanged }

    /// Where a system calendar will repeat this event differently from Lumen.
    public var compatibilityNotes: [String] {
        guard isSystemEvent, !showsStoredRecurrenceNote else { return [] }
        return services.organization.calendars.systemCompatibilityNotes(for: recurrence, timing: timing)
    }

    public var canSave: Bool {
        !isSaving && !isReadOnly && destination != nil && title.collapsingWhitespace.nonBlank != nil && end >= start
    }

    public func load() async {
        let service = services.organization.calendars
        do {
            calendars = try await service.calendars()
            systemAccess = await service.systemCalendarAccess()
            systemCalendars = try await service.writableSystemCalendars()
            if let systemEventIdentifier {
                let form = try await service.systemEvent(systemEventIdentifier)
                apply(form.record)
                recurrence = form.recurrence
                storedRecurrenceNote = form.recurrenceNote
                otherAlertCount = form.record.fixedAlertCount
                isReadOnly = !form.isEditable
                systemCalendarTitle = form.calendarTitle
                destination = .system(form.record.calendarID)
            } else if let eventID, let event = try await service.event(eventID) {
                title = event.title
                location = event.location
                notes = event.notes
                recurrence = event.recurrence
                reminderOffsets = event.reminderOffsets
                destination = .lumen(event.calendarID)
                apply(event.timing)
            } else if destination == nil {
                destination = calendars.first.map { .lumen($0.id) }
            }
            recurrenceChanged = false
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// Asks for access to the system calendars (new events only) and lists them when granted.
    public func requestSystemAccess() async {
        let service = services.organization.calendars
        do {
            systemAccess = try await service.requestSystemCalendarAccess()
            systemCalendars = try await service.writableSystemCalendars()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// Lets the user replace a stored repeat rule Lumen can't show.
    public func replaceStoredRecurrence() {
        recurrence = nil
        recurrenceChanged = true
    }

    /// Saves the event; `false` with `error` set when it could not be saved.
    @discardableResult
    public func save() async -> Bool {
        guard let destination else {
            error = ErrorPresentation(title: "Choose a calendar", message: "Pick the calendar this event belongs to.")
            return false
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let draft = EventDraft(
            title: title, notes: notes, location: location,
            timing: timing, recurrence: recurrence, reminderOffsets: reminderOffsets
        )
        let service = services.organization.calendars
        do {
            switch destination {
            case .lumen(let calendarID):
                var lumenDraft = draft
                lumenDraft.calendarID = calendarID
                if let eventID {
                    _ = try await service.updateEvent(eventID, lumenDraft)
                } else {
                    _ = try await service.createEvent(lumenDraft)
                }
            case .system(let calendarID):
                try await service.saveSystemEvent(
                    draft,
                    toCalendar: calendarID,
                    identifier: systemEventIdentifier,
                    keepingRecurrence: showsStoredRecurrenceNote
                )
            }
            return true
        } catch {
            self.error = ErrorPresentation.from(error)
            return false
        }
    }

    public func delete() async -> Bool {
        let service = services.organization.calendars
        do {
            if let systemEventIdentifier {
                try await service.deleteSystemEvent(systemEventIdentifier)
            } else if let eventID {
                try await service.deleteEvent(eventID)
            } else {
                return false
            }
            return true
        } catch {
            self.error = ErrorPresentation.from(error)
            return false
        }
    }

    private var timing: EventTiming {
        let calendar = services.calendar
        return isAllDay
            ? .allDay(start: CalendarDate(start, calendar: calendar), end: CalendarDate(end, calendar: calendar))
            : .timed(start: start, end: end, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    private func apply(_ record: ExternalEventRecord) {
        title = record.title
        location = record.location
        notes = record.notes
        reminderOffsets = record.alertOffsets
        apply(record.timing)
    }

    private func apply(_ timing: EventTiming) {
        switch timing {
        case .timed(let start, let end, _):
            isAllDay = false
            self.start = start
            self.end = end
        case .allDay(let first, let last):
            isAllDay = true
            start = first.startDate(in: services.calendar)
            end = last.startDate(in: services.calendar)
        }
    }
}
