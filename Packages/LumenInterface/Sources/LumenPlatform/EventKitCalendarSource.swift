#if canImport(EventKit)
import Foundation
@preconcurrency import EventKit
import LumenFoundation
import LumenOrganization

/// The system calendar store as a read-only `ExternalCalendarSource`.
public actor EventKitCalendarSource: ExternalCalendarSource {
    private let store = EKEventStore()
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public enum Access: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
    }

    public func access() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func isAuthorized() async -> Bool {
        access() == .granted
    }

    /// Asks for full read access; returns whether it was granted.
    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func occurrences(from start: Date, to end: Date) async throws -> [EventOccurrence] {
        guard access() == .granted, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> EventOccurrence? in
            guard let eventStart = event.startDate, let eventEnd = event.endDate else { return nil }
            let lastInstant = eventEnd > eventStart ? eventEnd.addingTimeInterval(-1) : eventEnd
            return EventOccurrence(
                source: .external(identifier: event.eventIdentifier ?? UUID().uuidString, calendarName: event.calendar?.title ?? "Calendar"),
                title: event.title ?? "Untitled event",
                location: event.location ?? "",
                start: eventStart,
                end: eventEnd,
                isAllDay: event.isAllDay,
                firstDay: CalendarDate(eventStart, calendar: calendar),
                lastDay: CalendarDate(lastInstant, calendar: calendar),
                color: .slate
            )
        }
    }
}
#endif
