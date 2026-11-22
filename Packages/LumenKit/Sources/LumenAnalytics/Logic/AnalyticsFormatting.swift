import Foundation
import LumenFoundation

/// Deterministic English formatting for insight and report text. It deliberately avoids locale
/// lookups so the same data always produces the same sentence (and the same snapshot in tests).
enum AnalyticsFormatting {
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Tue 17 Nov".
    static func shortDay(_ day: CalendarDate) -> String {
        "\(day.weekday.shortName) \(day.day) \(monthName(day.month))"
    }

    /// "Tue 17 Nov 2026".
    static func longDay(_ day: CalendarDate) -> String {
        "\(shortDay(day)) \(day.year)"
    }

    /// "Tue 17 Nov 2026 – Mon 23 Nov 2026", or a single day.
    static func range(_ range: DayRange) -> String {
        range.start == range.end ? longDay(range.start) : "\(longDay(range.start)) – \(longDay(range.end))"
    }

    /// "1 task", "14 tasks".
    static func count(_ value: Int, _ unit: WorkUnit) -> String {
        "\(value) \(unit.noun(for: value))"
    }

    /// "1 day", "5 days".
    static func days(_ value: Int) -> String {
        value == 1 ? "1 day" : "\(value) days"
    }

    /// A span of days ending today, introduced by `preposition`: "in the last 7 days",
    /// "over the last 8 weeks" (whole weeks from two weeks on), or "today" for a single day.
    static func span(_ dayCount: Int, _ preposition: String) -> String {
        if dayCount <= 1 { return "today" }
        if dayCount >= 14, dayCount % 7 == 0 { return "\(preposition) the last \(dayCount / 7) weeks" }
        return "\(preposition) the last \(dayCount) days"
    }

    /// An average count with its noun: "4.2 tasks", "1 task".
    static func averageCount(_ value: Double, _ unit: WorkUnit) -> String {
        let text = decimal(value)
        return "\(text) \(text == "1" ? unit.singular : unit.plural)"
    }

    /// Magnitude of a percentage, rounded to a whole number: "40%".
    static func percent(_ value: Double) -> String {
        "\(abs(roundedInt(value)))%"
    }

    /// Signed percentage: "+40%", "-25%", "0%".
    static func signedPercent(_ value: Double) -> String {
        let rounded = roundedInt(value)
        if rounded > 0 { return "+\(rounded)%" }
        if rounded < 0 { return "-\(abs(rounded))%" }
        return "0%"
    }

    /// One decimal place without trailing ".0": "4.2", "3".
    static func decimal(_ value: Double) -> String {
        let tenths = roundedInt(value * 10)
        let sign = tenths < 0 ? "-" : ""
        let magnitude = abs(tenths)
        return magnitude % 10 == 0 ? "\(sign)\(magnitude / 10)" : "\(sign)\(magnitude / 10).\(magnitude % 10)"
    }

    /// Whole numbers without a decimal point, other values with one decimal.
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(roundedInt(value)) : decimal(value)
    }

    /// "09:00".
    static func hour(_ hour: Int) -> String {
        hour < 10 ? "0\(hour):00" : "\(hour):00"
    }

    /// The hour slot "09:00–10:00" (the last slot ends at "24:00").
    static func hourSlot(_ hour: Int) -> String {
        "\(self.hour(hour))–\(self.hour(hour + 1))"
    }

    static func roundedInt(_ value: Double) -> Int {
        // Inputs are counts and ratios of counts, always finite and small; the guard only keeps
        // the conversion total instead of trapping on a value that cannot occur.
        guard value.isFinite, abs(value) < 1e15 else { return 0 }
        return Int(value.rounded())
    }

    private static func monthName(_ month: Int) -> String {
        monthNames.indices.contains(month - 1) ? monthNames[month - 1] : String(month)
    }
}
