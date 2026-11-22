import Foundation
import LumenFoundation

/// What to do with a schedule at a given moment.
public struct ScheduleDecision: Sendable, Hashable {
    /// Whether the workflow should run now.
    public var isDue: Bool
    /// How many occurrences this single run stands for (0 when not due). More than 1 means the
    /// device missed occurrences; they are coalesced into one run rather than replayed.
    public var coalescedOccurrences: Int
    /// The next fire date to store after acting on this decision; `nil` when the series has ended.
    public var nextFireDate: Date?

    public init(isDue: Bool, coalescedOccurrences: Int, nextFireDate: Date?) {
        self.isDue = isDue
        self.coalescedOccurrences = coalescedOccurrences
        self.nextFireDate = nextFireDate
    }
}

/// Turns a `ScheduleTrigger` into instants, using `RecurrenceCalculator` for the days and the
/// injected calendar for the wall-clock time on each day.
public enum ScheduleCalculator {
    /// Upper bound on occurrences counted when coalescing a long gap.
    public static let maximumCoalescedCount = 1_000

    /// The first fire instant strictly after `instant`, or `nil` when the series has ended.
    public static func nextFireDate(for schedule: ScheduleTrigger, after instant: Date, calendar: Calendar) -> Date? {
        // An occurrence on an earlier day than `instant`'s fires before it, so start with that day.
        var after = CalendarDate(instant, calendar: calendar).adding(days: -1)
        // Each batch advances past at least one day; a handful of batches covers DST oddities.
        for _ in 0..<4 {
            let days = RecurrenceCalculator.occurrences(of: schedule.rule, anchor: schedule.anchor, after: after, limit: 4)
            guard let last = days.last else { return nil }
            for day in days {
                let date = schedule.time.date(on: day, calendar: calendar)
                if date > instant { return date }
            }
            after = last
        }
        return nil
    }

    /// Fire instants in `(start, end]`, at most `limit`.
    public static func fireDates(for schedule: ScheduleTrigger, after start: Date, through end: Date, calendar: Calendar, limit: Int) -> [Date] {
        guard end > start, limit > 0 else { return [] }
        let firstDay = CalendarDate(start, calendar: calendar).adding(days: -1)
        let lastDay = CalendarDate(end, calendar: calendar)
        return RecurrenceCalculator.occurrences(of: schedule.rule, anchor: schedule.anchor, after: firstDay, through: lastDay, limit: limit + 2)
            .map { schedule.time.date(on: $0, calendar: calendar) }
            .filter { $0 > start && $0 <= end }
            .prefix(limit)
            .map { $0 }
    }

    /// Decides whether a schedule whose next fire date was stored as `scheduledFireDate` is due at
    /// `now`. Missed occurrences collapse into one run; the next fire date is the first occurrence
    /// after `now`, so nothing is replayed. A `nil` stored date means "not scheduled yet": the
    /// first fire date after `now` is computed without firing.
    public static func decision(for schedule: ScheduleTrigger, scheduledFireDate: Date?, now: Date, calendar: Calendar) -> ScheduleDecision {
        guard let scheduled = scheduledFireDate else {
            return ScheduleDecision(isDue: false, coalescedOccurrences: 0, nextFireDate: nextFireDate(for: schedule, after: now, calendar: calendar))
        }
        guard scheduled <= now else {
            return ScheduleDecision(isDue: false, coalescedOccurrences: 0, nextFireDate: scheduled)
        }
        let missedAfterScheduled = fireDates(for: schedule, after: scheduled, through: now, calendar: calendar, limit: maximumCoalescedCount - 1).count
        return ScheduleDecision(
            isDue: true,
            coalescedOccurrences: 1 + missedAfterScheduled,
            nextFireDate: nextFireDate(for: schedule, after: now, calendar: calendar)
        )
    }
}
