#if canImport(EventKit)
import Foundation
@preconcurrency import EventKit
import LumenFoundation
import LumenOrganization

/// The system calendar store as an `ExternalCalendarSource`: reads occurrences for the agenda and
/// creates, changes and deletes events in calendars the user can write to. Recurring events are
/// always changed as a whole series.
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

    /// Asks for full access; returns whether it was granted.
    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    // MARK: - ExternalCalendarSource

    public func authorization() async -> ExternalCalendarAccess {
        switch access() {
        case .granted: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await requestAccess()
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

    public func calendars() async throws -> [ExternalCalendar] {
        guard access() == .granted else { return [] }
        return store.calendars(for: .event).map { item in
            ExternalCalendar(
                id: item.calendarIdentifier,
                title: item.title,
                sourceName: item.source?.title ?? "",
                isWritable: item.allowsContentModifications
            )
        }
    }

    public func event(identifier: String) async throws -> ExternalEventRecord? {
        guard access() == .granted, let event = store.event(withIdentifier: identifier) else { return nil }
        return record(from: event)
    }

    public func save(_ record: ExternalEventRecord) async throws -> String {
        guard access() == .granted else { throw OrganizationError.systemCalendarAccessDenied }
        guard let target = store.calendar(withIdentifier: record.calendarID) else { throw OrganizationError.systemCalendarNotFound }
        guard target.allowsContentModifications else { throw OrganizationError.systemCalendarReadOnly }

        let event: EKEvent
        if let identifier = record.identifier {
            guard let existing = store.event(withIdentifier: identifier) else { throw OrganizationError.systemEventNotFound }
            event = existing
        } else {
            event = EKEvent(eventStore: store)
        }
        event.calendar = target
        event.title = record.title
        event.notes = record.notes.isEmpty ? nil : record.notes
        event.location = record.location.isEmpty ? nil : record.location
        switch record.timing {
        case .timed(let start, let end, let zone):
            event.isAllDay = false
            event.timeZone = TimeZone(identifier: zone)
            event.startDate = start
            event.endDate = end
        case .allDay(let first, let last):
            event.isAllDay = true
            event.startDate = first.startDate(in: calendar)
            event.endDate = last.startDate(in: calendar)
        }
        if record.replacesRecurrence {
            event.recurrenceRules = record.recurrence.map { [Self.rule(from: $0)] }
        }
        // Alerts before the start are Lumen's to edit; any other alert (at a fixed date and time,
        // or after the start) is kept as it is.
        let kept = (event.alarms ?? []).filter { !Self.isEditableAlert($0) }
        event.alarms = kept + record.alertOffsets.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }

        try store.save(event, span: .futureEvents, commit: true)
        guard let identifier = event.eventIdentifier else { throw OrganizationError.systemEventNotFound }
        return identifier
    }

    public func deleteEvent(identifier: String) async throws {
        guard access() == .granted else { throw OrganizationError.systemCalendarAccessDenied }
        guard let event = store.event(withIdentifier: identifier) else { throw OrganizationError.systemEventNotFound }
        guard event.calendar?.allowsContentModifications ?? false else { throw OrganizationError.systemCalendarReadOnly }
        try store.remove(event, span: .futureEvents, commit: true)
    }

    // MARK: - Mapping

    private func record(from event: EKEvent) -> ExternalEventRecord? {
        guard let start = event.startDate, let end = event.endDate, let calendarID = event.calendar?.calendarIdentifier else { return nil }
        let timing: EventTiming
        if event.isAllDay {
            let lastInstant = end > start ? end.addingTimeInterval(-1) : end
            timing = .allDay(start: CalendarDate(start, calendar: calendar), end: CalendarDate(lastInstant, calendar: calendar))
        } else {
            timing = .timed(start: start, end: end, timeZoneIdentifier: (event.timeZone ?? calendar.timeZone).identifier)
        }
        let alarms = event.alarms ?? []
        let relative = alarms.filter(Self.isEditableAlert)
        return ExternalEventRecord(
            identifier: event.eventIdentifier,
            calendarID: calendarID,
            title: event.title ?? "",
            notes: event.notes ?? "",
            location: event.location ?? "",
            timing: timing,
            recurrence: event.recurrenceRules?.first.map(Self.recurrence(from:)),
            alertOffsets: relative.map { Int((-$0.relativeOffset / 60).rounded()) }.sorted(),
            fixedAlertCount: alarms.count - relative.count
        )
    }

    private static func isEditableAlert(_ alarm: EKAlarm) -> Bool {
        alarm.absoluteDate == nil && alarm.relativeOffset <= 0
    }

    static func rule(from recurrence: ExternalRecurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let days = recurrence.daysOfWeek.compactMap { entry -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: entry.weekday == .sunday ? 1 : entry.weekday.rawValue + 1) else { return nil }
            return entry.week == 0 ? EKRecurrenceDayOfWeek(weekday) : EKRecurrenceDayOfWeek(weekday, weekNumber: entry.week)
        }
        let end: EKRecurrenceEnd?
        switch recurrence.end {
        case .never: end = nil
        case .count(let count): end = EKRecurrenceEnd(occurrenceCount: count)
        case .until(let date): end = EKRecurrenceEnd(end: date)
        }
        func numbers(_ values: [Int]) -> [NSNumber]? { values.isEmpty ? nil : values.map { NSNumber(value: $0) } }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: recurrence.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(recurrence.daysOfMonth),
            monthsOfTheYear: numbers(recurrence.monthsOfYear),
            weeksOfTheYear: numbers(recurrence.weeksOfYear),
            daysOfTheYear: numbers(recurrence.daysOfYear),
            setPositions: numbers(recurrence.setPositions),
            end: end
        )
    }

    static func recurrence(from rule: EKRecurrenceRule) -> ExternalRecurrence {
        let frequency: ExternalRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .yearly
        }
        let days = (rule.daysOfTheWeek ?? []).compactMap { entry -> ExternalRecurrence.DayOfWeek? in
            // EKWeekday: Sunday = 1 … Saturday = 7; Lumen's Weekday is ISO (Monday = 1).
            let raw = entry.dayOfTheWeek.rawValue
            guard let weekday = Weekday(rawValue: raw == 1 ? 7 : raw - 1) else { return nil }
            return ExternalRecurrence.DayOfWeek(weekday: weekday, week: entry.weekNumber)
        }
        let end: ExternalRecurrence.End
        if let recurrenceEnd = rule.recurrenceEnd {
            if let date = recurrenceEnd.endDate {
                end = .until(date)
            } else {
                end = .count(recurrenceEnd.occurrenceCount)
            }
        } else {
            end = .never
        }
        func ints(_ values: [NSNumber]?) -> [Int] { (values ?? []).map(\.intValue) }
        return ExternalRecurrence(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: days,
            daysOfMonth: ints(rule.daysOfTheMonth),
            monthsOfYear: ints(rule.monthsOfTheYear),
            weeksOfYear: ints(rule.weeksOfTheYear),
            daysOfYear: ints(rule.daysOfTheYear),
            setPositions: ints(rule.setPositions),
            end: end
        )
    }
}
#endif
