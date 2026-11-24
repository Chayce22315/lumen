import Foundation

/// Abstraction over "now" so that every time-dependent rule (due dates, schedules, greetings,
/// retention windows, retry backoff) is deterministic under test.
public protocol TimeSource: Sendable {
    func now() -> Date
}

/// Wall-clock time.
public struct SystemTimeSource: TimeSource {
    public init() {}

    public func now() -> Date { Date() }
}
