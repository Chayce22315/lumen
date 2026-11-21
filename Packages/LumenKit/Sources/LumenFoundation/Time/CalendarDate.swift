import Foundation

/// A calendar day without a time or time zone ("due on 21 November").
///
/// All-day values must not be stored as `Date`: a `Date` is an instant, and the same instant is a
/// different day in different time zones. `CalendarDate` is converted to an instant only at the
/// edges, using the caller's calendar.
public struct CalendarDate: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Validated initializer. Returns `nil` for impossible dates such as 2026-02-30.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard day <= CalendarDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        // Components from a real Date are always populated for the gregorian-style calendars we use.
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    /// Start of this day in `calendar`'s time zone.
    public func startDate(in calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        // A validated year/month/day always resolves; the fallback keeps this total without a force unwrap.
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int) -> CalendarDate {
        CalendarDate(julianDay: julianDay + days)
    }

    /// Signed number of days from `other` to `self`.
    public func days(since other: CalendarDate) -> Int {
        julianDay - other.julianDay
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        // Julian day 0 was a Monday.
        ((julianDay % 7) + 7) % 7 + 1
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    // MARK: - Julian day arithmetic (proleptic Gregorian)

    /// Days since the epoch used by the conversion below; only differences are meaningful.
    var julianDay: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    init(julianDay jd: Int) {
        let a = jd + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        self.day = e - (153 * m + 2) / 5 + 1
        self.month = m + 3 - 12 * (m / 10)
        self.year = 100 * b + d - 4800 + m / 10
    }
}

extension CalendarDate: CustomStringConvertible, LosslessStringConvertible {
    /// `YYYY-MM-DD`.
    public var description: String {
        "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
    }

    public init?(_ description: String) {
        let parts = description.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

extension CalendarDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = CalendarDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid calendar date '\(text)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
