import Foundation
import Synchronization

/// Fan-out point for all logging. One instance is created by the composition root and handed to
/// services as category-scoped `Logger` values.
public final class LoggingSystem: Sendable {
    private struct State {
        var sinks: [any LogSink]
        var minimumLevel: LogLevel
    }

    private let state: Mutex<State>
    private let timeSource: any TimeSource

    public init(sinks: [any LogSink], minimumLevel: LogLevel = .info, timeSource: any TimeSource = SystemTimeSource()) {
        self.state = Mutex(State(sinks: sinks, minimumLevel: minimumLevel))
        self.timeSource = timeSource
    }

    public func logger(_ category: String) -> Logger {
        Logger(category: category, system: self)
    }

    public func addSink(_ sink: any LogSink) {
        state.withLock { $0.sinks.append(sink) }
    }

    public var minimumLevel: LogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = newValue } }
    }

    func isEnabled(_ level: LogLevel) -> Bool {
        state.withLock { level >= $0.minimumLevel }
    }

    func dispatch(level: LogLevel, category: String, message: String, metadata: [String: String]) {
        let sinks: [any LogSink] = state.withLock { state in
            level >= state.minimumLevel ? state.sinks : []
        }
        guard !sinks.isEmpty else { return }
        let entry = LogEntry(date: timeSource.now(), level: level, category: category, message: message, metadata: metadata)
        for sink in sinks {
            sink.record(entry)
        }
    }
}

/// A category-scoped logger. Cheap to copy; message construction is skipped when the level is disabled.
public struct Logger: Sendable {
    public let category: String
    private let system: LoggingSystem?

    init(category: String, system: LoggingSystem?) {
        self.category = category
        self.system = system
    }

    /// A logger that discards everything. For previews and tests that do not assert on logs.
    public static func disabled(_ category: String = "disabled") -> Logger {
        Logger(category: category, system: nil)
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        guard let system, system.isEnabled(level) else { return }
        system.dispatch(level: level, category: category, message: message(), metadata: metadata)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.debug, message(), metadata: metadata)
    }

    public func info(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.info, message(), metadata: metadata)
    }

    public func notice(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.notice, message(), metadata: metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.warning, message(), metadata: metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.error, message(), metadata: metadata)
    }

    /// Logs an error value with its type and description.
    public func error(_ message: @autoclosure () -> String, error: any Error, metadata: [String: String] = [:]) {
        var combined = metadata
        combined["error.type"] = String(describing: type(of: error))
        combined["error"] = String(describing: error)
        log(.error, message(), metadata: combined)
    }
}
