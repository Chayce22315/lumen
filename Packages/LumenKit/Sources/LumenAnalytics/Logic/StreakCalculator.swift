import Foundation
import LumenFoundation

/// Runs of consecutive active days.
///
/// "Active" is whatever the caller decides (usually: at least one completion). Days are calendar
/// days already resolved in the user's calendar, so time-zone boundaries are handled when events
/// are recorded, not here.
public enum StreakCalculator {
    /// The streak that is still alive on `today`: consecutive active days ending today, or ending
    /// yesterday when today has no activity yet (the day is not over, so the streak is not broken).
    /// `nil` when neither today nor yesterday was active. Days after `today` are ignored.
    public static func currentStreak(activeDays: Set<CalendarDate>, today: CalendarDate) -> Streak? {
        let yesterday = today.adding(days: -1)
        let end: CalendarDate
        if activeDays.contains(today) {
            end = today
        } else if activeDays.contains(yesterday) {
            end = yesterday
        } else {
            return nil
        }
        var start = end
        while activeDays.contains(start.adding(days: -1)) {
            start = start.adding(days: -1)
        }
        return Streak(start: start, end: end)
    }

    /// Length in days of `currentStreak`, 0 when there is none.
    public static func currentStreakLength(activeDays: Set<CalendarDate>, today: CalendarDate) -> Int {
        currentStreak(activeDays: activeDays, today: today)?.length ?? 0
    }

    /// Every maximal run of active days inside `range`, oldest first. Runs that extend beyond the
    /// range are clipped to it.
    public static func streaks(activeDays: Set<CalendarDate>, in range: DayRange) -> [Streak] {
        let days = activeDays.filter(range.contains).sorted()
        guard var runStart = days.first else { return [] }
        var runEnd = runStart
        var result: [Streak] = []
        for day in days.dropFirst() {
            if day.days(since: runEnd) == 1 {
                runEnd = day
            } else {
                result.append(Streak(start: runStart, end: runEnd))
                runStart = day
                runEnd = day
            }
        }
        result.append(Streak(start: runStart, end: runEnd))
        return result
    }

    /// The longest run of active days inside `range`; among equally long runs, the earliest.
    /// `nil` when the range has no active day.
    public static func longestStreak(activeDays: Set<CalendarDate>, in range: DayRange) -> Streak? {
        var best: Streak?
        for streak in streaks(activeDays: activeDays, in: range) where streak.length > (best?.length ?? 0) {
            best = streak
        }
        return best
    }
}
