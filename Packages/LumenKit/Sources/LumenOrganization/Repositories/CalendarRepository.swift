import Foundation
import LumenFoundation
import LumenPersistence

public struct CalendarRepository: Sendable {
    public init() {}

    // MARK: Calendars

    public func save(_ calendar: LumenCalendar, in db: DatabaseConnection) throws {
        try upsertRow(calendar, in: db)
        try db.recordUpsert(calendar.reference, snapshot: calendar)
    }

    public func upsertRow(_ calendar: LumenCalendar, in db: DatabaseConnection) throws {
        try db.execute(
            "INSERT OR REPLACE INTO organization_calendars (id, name, color, is_visible, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            calendar.rowArguments
        )
    }

    public func delete(_ id: LumenCalendar.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .calendar, id: id))
    }

    public func deleteRow(_ id: LumenCalendar.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM organization_calendars WHERE id = ?", [id])
    }

    public func calendar(_ id: LumenCalendar.ID, in db: DatabaseConnection) throws -> LumenCalendar? {
        try db.queryFirst("SELECT * FROM organization_calendars WHERE id = ?", [id]).map(LumenCalendar.init(row:))
    }

    public func calendars(in db: DatabaseConnection) throws -> [LumenCalendar] {
        try db.query("SELECT * FROM organization_calendars ORDER BY created_at, id").map(LumenCalendar.init(row:))
    }

    // MARK: Events

    public func save(_ event: CalendarEvent, in db: DatabaseConnection) throws {
        try upsertRow(event, in: db)
        try db.recordUpsert(event.reference, snapshot: event)
    }

    public func upsertRow(_ event: CalendarEvent, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT OR REPLACE INTO organization_events
                (id, calendar_id, title, notes, location, timing, range_start, range_end, recurrence, reminder_offsets, project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            event.rowArguments
        )
    }

    public func delete(_ id: CalendarEvent.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .calendarEvent, id: id))
    }

    public func deleteRow(_ id: CalendarEvent.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM organization_events WHERE id = ?", [id])
    }

    public func event(_ id: CalendarEvent.ID, in db: DatabaseConnection) throws -> CalendarEvent? {
        try db.queryFirst("SELECT * FROM organization_events WHERE id = ?", [id]).map(CalendarEvent.init(row:))
    }

    /// Events that may have an occurrence overlapping `[start, end)`.
    public func events(overlapping start: Date, _ end: Date, in db: DatabaseConnection) throws -> [CalendarEvent] {
        try db.query(
            "SELECT * FROM organization_events WHERE range_start < ? AND (range_end IS NULL OR range_end > ?) ORDER BY range_start",
            [end, start]
        ).map(CalendarEvent.init(row:))
    }

    public func events(inCalendar id: LumenCalendar.ID, in db: DatabaseConnection) throws -> [CalendarEvent] {
        try db.query("SELECT * FROM organization_events WHERE calendar_id = ?", [id]).map(CalendarEvent.init(row:))
    }

    public func allEvents(in db: DatabaseConnection) throws -> [CalendarEvent] {
        try db.query("SELECT * FROM organization_events ORDER BY range_start").map(CalendarEvent.init(row:))
    }
}
