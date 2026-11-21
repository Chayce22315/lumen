import Foundation
import Synchronization
import LumenFoundation

/// A clock tests move by hand.
public final class ManualTimeSource: TimeSource {
    private let current: Mutex<Date>

    public init(_ start: Date = ManualTimeSource.referenceDate) {
        self.current = Mutex(start)
    }

    public func now() -> Date {
        current.withLock { $0 }
    }

    public func set(_ date: Date) {
        current.withLock { $0 = date }
    }

    public func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    /// Saturday 21 November 2026, 09:00:00 UTC.
    public static let referenceDate = Date(timeIntervalSince1970: 1_795_251_600)
}

extension Calendar {
    /// A deterministic gregorian calendar in UTC with Monday as the first weekday.
    public static var testUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
