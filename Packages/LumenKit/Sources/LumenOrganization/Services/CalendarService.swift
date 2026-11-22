import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Input for creating or replacing an event.
public struct EventDraft: Sendable, Hashable {
    public var calendarID: LumenCalendar.ID?
    public var title: String
    public var notes: String
    public var location: String
    public var timing: EventTiming
    public var recurrence: RecurrenceRule?
    public var reminderOffsets: [Int]
    public var projectID: Project.ID?

    public init(
        calendarID: LumenCalendar.ID? = nil,
        title: String,
        notes: String = "",
        location: String = "",
        timing: EventTiming,
        recurrence: RecurrenceRule? = nil,
        reminderOffsets: [Int] = [],
        projectID: Project.ID? = nil
    ) {
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.location = location
        self.timing = timing
        self.recurrence = recurrence
        self.reminderOffsets = reminderOffsets
        self.projectID = projectID
    }
}

/// Calendars and events, merged with the external (system) calendar source. Writing to system
/// calendars lives in `CalendarService+System.swift`.
public final class CalendarService: Sendable {
    private let database: Database
    let events: EventBus
    let timeSource: any TimeSource
    let calendar: Calendar
    let external: (any ExternalCalendarSource)?
    let logger: Logger
    private let repository = CalendarRepository()

    public init(
        database: Database,
        events: EventBus,
        timeSource: any TimeSource,
        calendar: Calendar,
        external: (any ExternalCalendarSource)?,
        logger: Logger
    ) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.external = external
        self.logger = logger
    }

    // MARK: - Calendars

    /// Lumen needs one calendar to hold events. Creates "Personal" on first launch only.
    @discardableResult
    public func ensureDefaultCalendar() async throws -> LumenCalendar {
        let now = timeSource.now()
        let repository = self.repository
        let (calendar, created): (LumenCalendar, Bool) = try await database.write { db in
            if let existing = try repository.calendars(in: db).first { return (existing, false) }
            let calendar = LumenCalendar(name: "Personal", color: .blue, createdAt: now, updatedAt: now)
            try repository.save(calendar, in: db)
            return (calendar, true)
        }
        if created {
            events.publish(ActionContext.system.event(OrganizationEvent.calendarCreated, entity: calendar.reference, at: now))
        }
        return calendar
    }

    public func createCalendar(name: String, color: ProjectColor, context: ActionContext = .user) async throws -> LumenCalendar {
        guard let name = name.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "name", reason: "A calendar needs a name.")
        }
        let now = timeSource.now()
        let calendar = LumenCalendar(name: name, color: color, createdAt: now, updatedAt: now)
        let repository = self.repository
        try await database.write { db in try repository.save(calendar, in: db) }
        events.publish(context.event(OrganizationEvent.calendarCreated, entity: calendar.reference, at: now))
        return calendar
    }

    public func updateCalendar(_ id: LumenCalendar.ID, name: String? = nil, color: ProjectColor? = nil, isVisible: Bool? = nil, context: ActionContext = .user) async throws -> LumenCalendar {
        let now = timeSource.now()
        let repository = self.repository
        let updated: LumenCalendar = try await database.write { db in
            guard var calendar = try repository.calendar(id, in: db) else { throw OrganizationError.calendarNotFound(id) }
            if let name {
                guard let cleaned = name.collapsingWhitespace.nonBlank else {
                    throw ValidationError(field: "name", reason: "A calendar needs a name.")
                }
                calendar.name = cleaned
            }
            if let color { calendar.color = color }
            if let isVisible { calendar.isVisible = isVisible }
            calendar.updatedAt = now
            try repository.save(calendar, in: db)
            return calendar
        }
        events.publish(context.event(OrganizationEvent.calendarUpdated, entity: updated.reference, at: now))
        return updated
    }

    /// Deletes a calendar and its events. The last calendar cannot be deleted.
    public func deleteCalendar(_ id: LumenCalendar.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let repository = self.repository
        let removedEvents: [CalendarEvent.ID] = try await database.write { db in
            let calendars = try repository.calendars(in: db)
            guard calendars.contains(where: { $0.id == id }) else { throw OrganizationError.calendarNotFound(id) }
            guard calendars.count > 1 else { throw OrganizationError.lastCalendar }
            let owned = try repository.events(inCalendar: id, in: db)
            for event in owned {
                try repository.delete(event.id, in: db)
            }
            try repository.delete(id, in: db)
            return owned.map(\.id)
        }
        var published = removedEvents.map { context.event(OrganizationEvent.eventDeleted, entity: EntityReference(kind: .calendarEvent, id: $0), at: now) }
        published.append(context.event(OrganizationEvent.calendarDeleted, entity: EntityReference(kind: .calendar, id: id), at: now))
        events.publish(published)
    }

    public func calendars() async throws -> [LumenCalendar] {
        let repository = self.repository
        return try await database.read { db in try repository.calendars(in: db) }
    }

    // MARK: - Events

    public func createEvent(_ draft: EventDraft, context: ActionContext = .user) async throws -> CalendarEvent {
        let now = timeSource.now()
        let repository = self.repository
        let event: CalendarEvent = try await database.write { db in
            let calendarID: LumenCalendar.ID
            if let requested = draft.calendarID {
                guard try repository.calendar(requested, in: db) != nil else { throw OrganizationError.calendarNotFound(requested) }
                calendarID = requested
            } else if let first = try repository.calendars(in: db).first {
                calendarID = first.id
            } else {
                let created = LumenCalendar(name: "Personal", color: .blue, createdAt: now, updatedAt: now)
                try repository.save(created, in: db)
                calendarID = created.id
            }
            let event = try Self.validated(CalendarEvent(
                calendarID: calendarID,
                title: draft.title,
                notes: draft.notes,
                location: draft.location,
                timing: draft.timing,
                recurrence: draft.recurrence,
                reminderOffsets: draft.reminderOffsets,
                projectID: draft.projectID,
                createdAt: now,
                updatedAt: now
            ))
            try repository.save(event, in: db)
            return event
        }
        events.publish(context.event(OrganizationEvent.eventCreated, entity: event.reference, at: now))
        return event
    }

    /// Replaces an event's fields with `draft`.
    public func updateEvent(_ id: CalendarEvent.ID, _ draft: EventDraft, context: ActionContext = .user) async throws -> CalendarEvent {
        let now = timeSource.now()
        let repository = self.repository
        let event: CalendarEvent = try await database.write { db in
            guard var event = try repository.event(id, in: db) else { throw OrganizationError.eventNotFound(id) }
            if let calendarID = draft.calendarID {
                guard try repository.calendar(calendarID, in: db) != nil else { throw OrganizationError.calendarNotFound(calendarID) }
                event.calendarID = calendarID
            }
            event.title = draft.title
            event.notes = draft.notes
            event.location = draft.location
            event.timing = draft.timing
            event.recurrence = draft.recurrence
            event.reminderOffsets = draft.reminderOffsets
            event.projectID = draft.projectID
            event.updatedAt = now
            event = try Self.validated(event)
            try repository.save(event, in: db)
            return event
        }
        events.publish(context.event(OrganizationEvent.eventUpdated, entity: event.reference, at: now))
        return event
    }

    public func deleteEvent(_ id: CalendarEvent.ID, context: ActionContext = .user) async throws {
        let now = timeSource.now()
        let repository = self.repository
        try await database.write { db in
            guard try repository.event(id, in: db) != nil else { throw OrganizationError.eventNotFound(id) }
            try repository.delete(id, in: db)
        }
        events.publish(context.event(OrganizationEvent.eventDeleted, entity: EntityReference(kind: .calendarEvent, id: id), at: now))
    }

    public func event(_ id: CalendarEvent.ID) async throws -> CalendarEvent? {
        let repository = self.repository
        return try await database.read { db in try repository.event(id, in: db) }
    }

    public func allEvents() async throws -> [CalendarEvent] {
        let repository = self.repository
        return try await database.read { db in try repository.allEvents(in: db) }
    }

    /// Occurrences overlapping `[start, end)` from visible local calendars and the external source,
    /// sorted by start. A failing external source is logged and skipped, never fatal.
    public func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence] {
        let repository = self.repository
        let calendar = self.calendar
        let local: [EventOccurrence] = try await database.read { db in
            let calendars = Dictionary(try repository.calendars(in: db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return try repository.events(overlapping: start, end, in: db).flatMap { event -> [EventOccurrence] in
                guard let owner = calendars[event.calendarID], owner.isVisible else { return [] }
                return EventOccurrenceExpander.occurrences(of: event, color: owner.color, from: start, to: end, calendar: calendar)
            }
        }
        var merged = local
        if let external, await external.isAuthorized() {
            do {
                merged.append(contentsOf: try await external.occurrences(from: start, to: end))
            } catch {
                logger.error("External calendar could not be read", error: error)
            }
        }
        return merged.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    static func validated(_ event: CalendarEvent) throws -> CalendarEvent {
        var event = event
        guard let title = event.title.collapsingWhitespace.nonBlank else {
            throw ValidationError(field: "title", reason: "An event needs a title.")
        }
        event.title = title
        switch event.timing {
        case .timed(let start, let end, let zone):
            guard end >= start else { throw ValidationError(field: "end", reason: "An event can't end before it starts.") }
            guard end.timeIntervalSince(start) <= 366 * 86_400 else {
                throw ValidationError(field: "end", reason: "Events can last at most a year.")
            }
            guard TimeZone(identifier: zone) != nil else { throw ValidationError(field: "time zone", reason: "Unknown time zone.") }
        case .allDay(let start, let end):
            guard end >= start else { throw ValidationError(field: "end", reason: "An event can't end before it starts.") }
            guard end.days(since: start) <= 366 else { throw ValidationError(field: "end", reason: "Events can last at most a year.") }
        }
        guard event.reminderOffsets.allSatisfy({ (0...(60 * 24 * 14)).contains($0) }) else {
            throw ValidationError(field: "reminder", reason: "Reminders can be up to two weeks before the event.")
        }
        event.reminderOffsets = Array(Set(event.reminderOffsets)).sorted()
        return event
    }
}
