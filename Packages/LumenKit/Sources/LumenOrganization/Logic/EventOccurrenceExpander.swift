import Foundation
import LumenFoundation

/// Expands local events (including recurring ones) into concrete occurrences within a window.
public enum EventOccurrenceExpander {
    /// Hard cap per event and window, protecting the interface from pathological rules.
    static let maximumOccurrencesPerEvent = 1_000

    public static func occurrences(
        of event: CalendarEvent,
        color: ProjectColor,
        from windowStart: Date,
        to windowEnd: Date,
        calendar: Calendar
    ) -> [EventOccurrence] {
        guard windowEnd > windowStart else { return [] }
        switch event.timing {
        case .timed(let start, let end, let timeZoneIdentifier):
            var local = calendar
            if let zone = TimeZone(identifier: timeZoneIdentifier) {
                local.timeZone = zone
            }
            let duration = max(0, end.timeIntervalSince(start))
            let startDays = occurrenceDays(event: event, anchor: CalendarDate(start, calendar: local), windowStart: windowStart, windowEnd: windowEnd, calendar: local, spanDays: Int((duration / 86_400).rounded(.up)))
            let time = TimeOfDay(start, calendar: local)
            let seconds = local.component(.second, from: start)
            return startDays.compactMap { day -> EventOccurrence? in
                let occurrenceStart = time.date(on: day, calendar: local).addingTimeInterval(TimeInterval(seconds))
                let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)
                guard occurrenceEnd > windowStart || (duration == 0 && occurrenceStart >= windowStart), occurrenceStart < windowEnd else { return nil }
                let lastInstant = duration > 0 ? occurrenceEnd.addingTimeInterval(-1) : occurrenceEnd
                return EventOccurrence(
                    source: .local(event.id),
                    title: event.title,
                    location: event.location,
                    start: occurrenceStart,
                    end: occurrenceEnd,
                    isAllDay: false,
                    firstDay: CalendarDate(occurrenceStart, calendar: calendar),
                    lastDay: CalendarDate(lastInstant, calendar: calendar),
                    color: color
                )
            }

        case .allDay(let firstDay, let lastDay):
            let span = max(0, lastDay.days(since: firstDay))
            let days = occurrenceDays(event: event, anchor: firstDay, windowStart: windowStart, windowEnd: windowEnd, calendar: calendar, spanDays: span + 1)
            return days.compactMap { day -> EventOccurrence? in
                let end = day.adding(days: span)
                let startInstant = day.startDate(in: calendar)
                let endInstant = end.adding(days: 1).startDate(in: calendar)
                guard endInstant > windowStart, startInstant < windowEnd else { return nil }
                return EventOccurrence(
                    source: .local(event.id),
                    title: event.title,
                    location: event.location,
                    start: startInstant,
                    end: endInstant,
                    isAllDay: true,
                    firstDay: day,
                    lastDay: end,
                    color: color
                )
            }
        }
    }

    /// Start days of occurrences that may overlap the window (an occurrence starting up to
    /// `spanDays` before the window can still reach into it).
    private static func occurrenceDays(
        event: CalendarEvent,
        anchor: CalendarDate,
        windowStart: Date,
        windowEnd: Date,
        calendar: Calendar,
        spanDays: Int
    ) -> [CalendarDate] {
        guard let rule = event.recurrence else { return [anchor] }
        let firstWindowDay = CalendarDate(windowStart, calendar: calendar).adding(days: -max(1, spanDays))
        let lastWindowDay = CalendarDate(windowEnd, calendar: calendar)
        return RecurrenceCalculator.occurrences(
            of: rule,
            anchor: anchor,
            after: firstWindowDay.adding(days: -1),
            through: lastWindowDay,
            limit: maximumOccurrencesPerEvent
        )
    }
}
