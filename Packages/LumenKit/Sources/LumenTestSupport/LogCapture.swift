import Foundation
import Synchronization
import LumenFoundation

/// Captures log entries so tests can assert that failures are reported rather than swallowed.
public final class LogCapture: LogSink {
    private let entries = Mutex<[LogEntry]>([])

    public init() {}

    public func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }

    public var recorded: [LogEntry] {
        entries.withLock { $0 }
    }

    public func entries(atLeast level: LogLevel) -> [LogEntry] {
        recorded.filter { $0.level >= level }
    }

    /// A logging system that writes only to this capture.
    public func makeSystem(minimumLevel: LogLevel = .debug) -> LoggingSystem {
        LoggingSystem(sinks: [self], minimumLevel: minimumLevel)
    }
}
