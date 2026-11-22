import Foundation
import LumenFoundation
import LumenCore

/// A system-calendar event prepared for Lumen's event editor.
public struct SystemEventForm: Sendable, Hashable {
    public let record: ExternalEventRecord
    /// The repeat rule in Lumen's terms; `nil` when there is none or it can't be shown.
    public let recurrence: RecurrenceRule?
    /// Why the stored repeat rule can't be edited here, when it can't.
    public let recurrenceNote: String?
    /// `false` when the event's calendar is read-only.
    public let isEditable: Bool
    public let calendarTitle: String

    /// Whether the stored repeat rule is one Lumen can show and change.
    public var isRecurrenceEditable: Bool { recurrenceNote == nil }
}

/// Events in the user's system calendars (iCloud, Google, Exchange, …), created and changed through
/// the `ExternalCalendarSource`. They are never copied into Lumen's database.
extension CalendarService {
    /// Whether this build has a system calendar store at all (not in tests, previews or Linux).
    public var supportsSystemCalendars: Bool { external != nil }

    /// `nil` when there is no system calendar store.
    public func systemCalendarAccess() async -> ExternalCalendarAccess? {
        guard let external else { return nil }
        return await external.authorization()
    }

    /// Asks for access when it has not been decided yet; returns the resulting state.
    @discardableResult
    public func requestSystemCalendarAccess() async throws -> ExternalCalendarAccess {
        guard let external else { throw OrganizationError.systemCalendarUnavailable }
        if await external.authorization() == .notDetermined {
            _ = try await external.requestAuthorization()
        }
        return await external.authorization()
    }

    /// Calendars new events can be saved to; empty without access.
    public func writableSystemCalendars() async throws -> [ExternalCalendar] {
        guard let external, await external.authorization() == .granted else { return [] }
        return try await external.calendars()
            .filter(\.isWritable)
            .sorted { ($0.sourceName, $0.title) < ($1.sourceName, $1.title) }
    }

    /// An existing system event for editing.
    public func systemEvent(_ identifier: String) async throws -> SystemEventForm {
        let external = try await authorizedExternal()
        guard let record = try await external.event(identifier: identifier) else { throw OrganizationError.systemEventNotFound }
        let owner = try await external.calendars().first { $0.id == record.calendarID }
        let inbound = record.recurrence.map { ExternalRecurrenceMapping.inbound($0, calendar: calendar) }
        return SystemEventForm(
            record: record,
            recurrence: inbound?.rule,
            recurrenceNote: inbound?.note,
            isEditable: owner?.isWritable ?? false,
            calendarTitle: owner?.title ?? "Calendar"
        )
    }

    /// Creates (`identifier == nil`) or replaces a system event from an editor draft and returns
    /// its identifier. With `keepingRecurrence`, the stored repeat rule is left untouched (for
    /// rules Lumen can't show). Validation is the same as for Lumen events.
    @discardableResult
    public func saveSystemEvent(
        _ draft: EventDraft,
        toCalendar calendarID: String,
        identifier: String? = nil,
        keepingRecurrence: Bool = false,
        context: ActionContext = .user
    ) async throws -> String {
        let external = try await authorizedExternal()
        guard let target = try await external.calendars().first(where: { $0.id == calendarID }) else {
            throw OrganizationError.systemCalendarNotFound
        }
        guard target.isWritable else { throw OrganizationError.systemCalendarReadOnly }

        let now = timeSource.now()
        let checked = try Self.validated(CalendarEvent(
            calendarID: LumenCalendar.ID(),
            title: draft.title,
            notes: draft.notes,
            location: draft.location,
            timing: draft.timing,
            recurrence: draft.recurrence,
            reminderOffsets: draft.reminderOffsets,
            createdAt: now,
            updatedAt: now
        ))
        let recurrence = checked.recurrence.map {
            ExternalRecurrenceMapping.outbound($0, anchor: Self.firstDay(of: checked.timing, calendar: calendar), calendar: calendar).recurrence
        }
        let record = ExternalEventRecord(
            identifier: identifier,
            calendarID: calendarID,
            title: checked.title,
            notes: checked.notes,
            location: checked.location,
            timing: checked.timing,
            recurrence: recurrence,
            replacesRecurrence: !keepingRecurrence,
            alertOffsets: checked.reminderOffsets
        )
        let saved = try await external.save(record)
        events.publish(context.event(OrganizationEvent.systemEventSaved, entity: SystemCalendarEventReference.reference(for: saved), at: now))
        logger.info("System calendar event saved", metadata: ["created": identifier == nil ? "true" : "false"])
        return saved
    }

    /// Deletes a system event (a recurring event's whole series).
    public func deleteSystemEvent(_ identifier: String, context: ActionContext = .user) async throws {
        let external = try await authorizedExternal()
        try await external.deleteEvent(identifier: identifier)
        events.publish(context.event(OrganizationEvent.systemEventDeleted, entity: SystemCalendarEventReference.reference(for: identifier), at: timeSource.now()))
    }

    /// Where a system calendar would repeat `recurrence` differently from Lumen, for the editor
    /// to show before saving.
    public func systemCompatibilityNotes(for recurrence: RecurrenceRule?, timing: EventTiming) -> [String] {
        guard let recurrence else { return [] }
        return ExternalRecurrenceMapping.outbound(recurrence, anchor: Self.firstDay(of: timing, calendar: calendar), calendar: calendar).notes
    }

    private func authorizedExternal() async throws -> any ExternalCalendarSource {
        guard let external else { throw OrganizationError.systemCalendarUnavailable }
        guard await external.authorization() == .granted else { throw OrganizationError.systemCalendarAccessDenied }
        return external
    }

    static func firstDay(of timing: EventTiming, calendar: Calendar) -> CalendarDate {
        switch timing {
        case .timed(let start, _, let zone):
            var local = calendar
            if let timeZone = TimeZone(identifier: zone) { local.timeZone = timeZone }
            return CalendarDate(start, calendar: local)
        case .allDay(let start, _):
            return start
        }
    }
}
