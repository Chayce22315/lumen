import Foundation
import LumenFoundation

/// A calendar that groups events. Local calendars live in Lumen's database; external calendars
/// (from the system calendar store) are read through `ExternalCalendarSource` and never stored.
public struct LumenCalendar: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<LumenCalendar>

    public let id: ID
    public var name: String
    public var color: ProjectColor
    public var isVisible: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: ID = ID(), name: String, color: ProjectColor = .blue, isVisible: Bool = true, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.color = color
        self.isVisible = isVisible
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reference: EntityReference { EntityReference(kind: .calendar, id: id) }
}

/// When an event happens.
public enum EventTiming: Sendable, Hashable, Codable {
    /// A span of time. The time zone identifier anchors recurring occurrences to local wall time
    /// ("every Monday at 09:00 in Berlin" stays at 09:00 across DST).
    case timed(start: Date, end: Date, timeZoneIdentifier: String)
    /// Whole days, `end` inclusive.
    case allDay(start: CalendarDate, end: CalendarDate)

    public var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }
}

public struct CalendarEvent: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<CalendarEvent>

    public let id: ID
    public var calendarID: LumenCalendar.ID
    public var title: String
    public var notes: String
    public var location: String
    public var timing: EventTiming
    public var recurrence: RecurrenceRule?
    /// Minutes before the start at which to remind; empty for none.
    public var reminderOffsets: [Int]
    public var projectID: Project.ID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        calendarID: LumenCalendar.ID,
        title: String,
        notes: String = "",
        location: String = "",
        timing: EventTiming,
        recurrence: RecurrenceRule? = nil,
        reminderOffsets: [Int] = [],
        projectID: Project.ID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.location = location
        self.timing = timing
        self.recurrence = recurrence
        self.reminderOffsets = reminderOffsets
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reference: EntityReference { EntityReference(kind: .calendarEvent, id: id) }
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, calendarID, title, notes, location, timing, recurrence, reminderOffsets, projectID, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ID.self, forKey: .id)
        self.calendarID = try c.decode(LumenCalendar.ID.self, forKey: .calendarID)
        self.title = try c.decode(String.self, forKey: .title)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        self.timing = try c.decode(EventTiming.self, forKey: .timing)
        self.recurrence = try c.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        self.reminderOffsets = try c.decodeIfPresent([Int].self, forKey: .reminderOffsets) ?? []
        self.projectID = try c.decodeIfPresent(Project.ID.self, forKey: .projectID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// One concrete occurrence of an event (recurring events expand into many).
public struct EventOccurrence: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case local(CalendarEvent.ID)
        /// An event from the system calendar store, identified by its external identifier.
        case external(identifier: String, calendarName: String)
    }

    public let source: Source
    public let title: String
    public let location: String
    /// `start`/`end` for timed occurrences; for all-day occurrences the days are in `days`.
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let firstDay: CalendarDate
    public let lastDay: CalendarDate
    public let color: ProjectColor

    public init(source: Source, title: String, location: String, start: Date, end: Date, isAllDay: Bool, firstDay: CalendarDate, lastDay: CalendarDate, color: ProjectColor) {
        self.source = source
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.color = color
    }

    public var id: String {
        switch source {
        case .local(let id): return "\(id.uuidString)@\(firstDay)"
        case .external(let identifier, _): return "ext:\(identifier)@\(start.timeIntervalSince1970)"
        }
    }

    public func covers(_ day: CalendarDate) -> Bool {
        firstDay <= day && day <= lastDay
    }
}

/// A calendar source outside Lumen (the system calendar store on Apple platforms). Reading is
/// required; writing has read-only defaults (see `ExternalCalendarModels.swift`).
public protocol ExternalCalendarSource: Sendable {
    /// Whether the user granted access. Sources that are not authorized return no events.
    func isAuthorized() async -> Bool
    func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence]

    func authorization() async -> ExternalCalendarAccess
    /// Asks the user for access; returns whether it was granted.
    func requestAuthorization() async throws -> Bool
    /// Every calendar in the store, writable or not.
    func calendars() async throws -> [ExternalCalendar]
    /// The event (for a recurring event: the series), or `nil` when it no longer exists.
    func event(identifier: String) async throws -> ExternalEventRecord?
    /// Creates or replaces an event (a recurring event's whole series); returns its identifier.
    func save(_ event: ExternalEventRecord) async throws -> String
    /// Deletes an event (a recurring event's whole series).
    func deleteEvent(identifier: String) async throws
}
