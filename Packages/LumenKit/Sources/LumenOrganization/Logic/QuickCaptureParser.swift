import Foundation
import LumenFoundation

/// The structured result of parsing a quick-capture line.
public struct QuickCaptureResult: Sendable, Hashable {
    public var title: String
    public var dueDate: CalendarDate?
    public var dueTime: TimeOfDay?
    public var priority: TaskPriority
    public var tags: [String]
    /// A `+project` token, unresolved. The service matches it against existing projects.
    public var projectName: String?
    public var recurrence: RecurrenceRule?
    /// The fragments that were recognised, in input order, for highlighting in the capture field.
    public var recognized: [String]
}

/// Parses lines like `Call Sam tomorrow at 5pm !high #family every week` into task fields.
///
/// Recognised (case-insensitive):
/// - dates: `today`, `tonight`, `tomorrow`/`tmrw`, weekday names (`fri`, `on friday`, `next friday`
///   = the next such day after today), `next week` (next Monday), `next month` (the 1st),
///   `in 3 days|weeks|months`, `2026-12-01`, `dec 1`, `1 dec`, `december 1st`
/// - times: `at 5`, `5pm`, `5:30pm`, `17:30`, `noon`, `midnight`
/// - repetition: `daily`, `weekly`, `monthly`, `yearly`, `every day|weekday|week|month|year`,
///   `every 2 weeks`, `every monday`, `every mon and thu`
/// - `!low|!medium|!high|!urgent`, `!1`…`!4`; `#tag`; `+project`
///
/// Anything not recognised stays in the title. A line that is nothing but syntax keeps its raw
/// text as the title so a task is never created without one.
public enum QuickCaptureParser {
    public static func parse(_ input: String, today: CalendarDate) -> QuickCaptureResult {
        let tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var consumed = Array(repeating: false, count: tokens.count)
        var result = QuickCaptureResult(title: "", dueDate: nil, dueTime: nil, priority: .none, tags: [], projectName: nil, recurrence: nil, recognized: [])

        func lower(_ index: Int) -> String? {
            tokens.indices.contains(index) && !consumed[index] ? normalized(tokens[index]) : nil
        }
        func consume(_ range: ClosedRange<Int>) {
            for index in range { consumed[index] = true }
            result.recognized.append(tokens[range].joined(separator: " "))
        }

        var index = 0
        while index < tokens.count {
            guard !consumed[index], let word = lower(index) else { index += 1; continue }
            let raw = tokens[index]

            // Markers.
            if raw.hasPrefix("!"), raw.count > 1, let priority = priority(from: String(raw.dropFirst()).lowercased()) {
                result.priority = priority
                consume(index...index)
                index += 1
                continue
            }
            if raw.hasPrefix("#"), raw.count > 1 {
                let tag = TaskValidator.normalizedTags([raw])
                if let first = tag.first {
                    result.tags.append(first)
                    consume(index...index)
                }
                index += 1
                continue
            }
            if raw.hasPrefix("+"), raw.count > 1 {
                result.projectName = String(raw.dropFirst()).replacingOccurrences(of: "_", with: " ")
                consume(index...index)
                index += 1
                continue
            }

            // Repetition.
            if let (rule, length) = recurrence(at: index, lower: lower) {
                result.recurrence = rule
                consume(index...(index + length - 1))
                index += length
                continue
            }

            // Times, optionally introduced by "at".
            let timeStart = word == "at" ? index + 1 : index
            if let next = lower(timeStart), let time = time(from: next, allowBareHour: word == "at") {
                result.dueTime = time
                consume(index...timeStart)
                index = timeStart + 1
                continue
            }

            // Dates, optionally introduced by a connector.
            let connectors: Set<String> = ["on", "by", "due"]
            let dateStart = connectors.contains(word) ? index + 1 : index
            if let (date, length, impliedTime) = date(at: dateStart, today: today, lower: lower) {
                result.dueDate = date
                if let impliedTime, result.dueTime == nil {
                    result.dueTime = impliedTime
                }
                consume(index...(dateStart + length - 1))
                index = dateStart + length
                continue
            }

            index += 1
        }

        let title = zip(tokens, consumed).filter { !$0.1 }.map(\.0).joined(separator: " ").collapsingWhitespace
        result.title = title.isEmpty ? input.collapsingWhitespace : title
        if result.recurrence != nil && result.dueDate == nil {
            result.dueDate = firstOccurrence(of: result.recurrence, onOrAfter: today)
        }
        result.tags = TaskValidator.normalizedTags(result.tags)
        return result
    }

    // MARK: - Pieces

    private static func normalized(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;"))
    }

    static func priority(from text: String) -> TaskPriority? {
        switch text {
        case "low", "1": return .low
        case "med", "medium", "2": return .medium
        case "high", "3": return .high
        case "urgent", "4": return .urgent
        default: return nil
        }
    }

    static let weekdayNames: [String: Weekday] = [
        "monday": .monday, "mon": .monday,
        "tuesday": .tuesday, "tue": .tuesday, "tues": .tuesday,
        "wednesday": .wednesday, "wed": .wednesday,
        "thursday": .thursday, "thu": .thursday, "thur": .thursday, "thurs": .thursday,
        "friday": .friday, "fri": .friday,
        "saturday": .saturday, "sat": .saturday,
        "sunday": .sunday, "sun": .sunday,
    ]

    static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    /// `5pm`, `5:30pm`, `17:30`, `noon`, `midnight`; a bare hour (`5`) only after "at".
    static func time(from text: String, allowBareHour: Bool) -> TimeOfDay? {
        if text == "noon" { return TimeOfDay(hour: 12, minute: 0) }
        if text == "midnight" { return TimeOfDay(hour: 0, minute: 0) }
        var body = text
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            body.removeLast(suffix.count)
            break
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), parts[0].count <= 2 else { return nil }
        let minute: Int
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]) else { return nil }
            minute = value
        } else {
            guard meridiem != nil || allowBareHour else { return nil }
            minute = 0
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            let converted = meridiem == "am" ? (hour == 12 ? 0 : hour) : (hour == 12 ? 12 : hour + 12)
            return TimeOfDay(hour: converted, minute: minute)
        }
        return TimeOfDay(hour: hour, minute: minute)
    }

    /// Date expression starting at `index`: the date, tokens consumed, and an implied time (tonight).
    static func date(at index: Int, today: CalendarDate, lower: (Int) -> String?) -> (CalendarDate, Int, TimeOfDay?)? {
        guard let word = lower(index) else { return nil }
        switch word {
        case "today": return (today, 1, nil)
        case "tonight": return (today, 1, TimeOfDay(hour: 20, minute: 0))
        case "tomorrow", "tmrw", "tmr": return (today.adding(days: 1), 1, nil)
        default: break
        }
        if word == "next", let next = lower(index + 1) {
            if next == "week" { return (nextWeekday(.monday, after: today), 2, nil) }
            if next == "month", let first = CalendarDate(year: today.month == 12 ? today.year + 1 : today.year, month: today.month == 12 ? 1 : today.month + 1, day: 1) {
                return (first, 2, nil)
            }
            if let weekday = weekdayNames[next] { return (nextWeekday(weekday, after: today), 2, nil) }
        }
        if let weekday = weekdayNames[word] {
            return (nextWeekday(weekday, after: today), 1, nil)
        }
        if word == "in", let amountWord = lower(index + 1), let unit = lower(index + 2) {
            let amount = amountWord == "a" || amountWord == "an" ? 1 : Int(amountWord)
            if let amount, (1...999).contains(amount) {
                switch unit {
                case "day", "days": return (today.adding(days: amount), 3, nil)
                case "week", "weeks": return (today.adding(days: 7 * amount), 3, nil)
                case "month", "months": return (addingMonths(amount, to: today), 3, nil)
                default: break
                }
            }
        }
        if let iso = CalendarDate(word) {
            return (iso, 1, nil)
        }
        // "dec 1", "december 1st"
        if let month = monthNames[word], let dayWord = lower(index + 1), let day = dayNumber(dayWord),
           let date = upcoming(month: month, day: day, today: today) {
            return (date, 2, nil)
        }
        // "1 dec", "1st december"
        if let day = dayNumber(word), let monthWord = lower(index + 1), let month = monthNames[monthWord],
           let date = upcoming(month: month, day: day, today: today) {
            return (date, 2, nil)
        }
        return nil
    }

    static func recurrence(at index: Int, lower: (Int) -> String?) -> (RecurrenceRule, Int)? {
        guard let word = lower(index) else { return nil }
        switch word {
        case "daily": return (.daily, 1)
        case "weekly": return (.weekly, 1)
        case "monthly": return (.monthly, 1)
        case "yearly", "annually": return (.yearly, 1)
        default: break
        }
        guard word == "every", let next = lower(index + 1) else { return nil }
        if let unit = frequency(next) {
            return (RecurrenceRule(frequency: unit), 2)
        }
        if next == "weekday" || next == "weekdays" {
            return (.weekdaysOnly, 2)
        }
        if let interval = Int(next), (2...365).contains(interval), let unitWord = lower(index + 2), let unit = frequency(unitWord) {
            return (RecurrenceRule(frequency: unit, interval: interval), 3)
        }
        if weekdayNames[next] != nil {
            var weekdays: Set<Weekday> = []
            var cursor = index + 1
            while let candidate = lower(cursor) {
                if let weekday = weekdayNames[candidate] {
                    weekdays.insert(weekday)
                    cursor += 1
                } else if candidate == "and", let after = lower(cursor + 1), weekdayNames[after] != nil {
                    cursor += 1
                } else {
                    break
                }
            }
            return (RecurrenceRule(frequency: .weekly, weekdays: weekdays), cursor - index)
        }
        return nil
    }

    private static func frequency(_ word: String) -> RecurrenceRule.Frequency? {
        switch word {
        case "day", "days": return .daily
        case "week", "weeks": return .weekly
        case "month", "months": return .monthly
        case "year", "years": return .yearly
        default: return nil
        }
    }

    private static func dayNumber(_ word: String) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits.removeLast(2)
            break
        }
        guard let value = Int(digits), (1...31).contains(value) else { return nil }
        return value
    }

    /// The next `weekday` strictly after `today`.
    static func nextWeekday(_ weekday: Weekday, after today: CalendarDate) -> CalendarDate {
        let delta = (weekday.rawValue - today.isoWeekday + 7) % 7
        return today.adding(days: delta == 0 ? 7 : delta)
    }

    /// This year's date if still ahead (or today), otherwise next year's.
    private static func upcoming(month: Int, day: Int, today: CalendarDate) -> CalendarDate? {
        if let thisYear = CalendarDate(year: today.year, month: month, day: day), thisYear >= today {
            return thisYear
        }
        return CalendarDate(year: today.year + 1, month: month, day: day)
    }

    private static func addingMonths(_ months: Int, to date: CalendarDate) -> CalendarDate {
        let index = date.year * 12 + (date.month - 1) + months
        let year = index / 12
        let month = index % 12 + 1
        let day = min(date.day, CalendarDate.daysInMonth(year: year, month: month))
        return CalendarDate(year: year, month: month, day: day) ?? date
    }

    private static func firstOccurrence(of rule: RecurrenceRule?, onOrAfter today: CalendarDate) -> CalendarDate? {
        guard let rule else { return nil }
        if rule.frequency == .weekly, !rule.weekdays.isEmpty {
            return RecurrenceCalculator.occurrences(of: rule, anchor: today, limit: 1).first
        }
        return today
    }
}
