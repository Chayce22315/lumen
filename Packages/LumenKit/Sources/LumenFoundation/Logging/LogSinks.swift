import Foundation
import Synchronization
#if canImport(os)
import os
#endif

/// Keeps the most recent entries in memory for the in-app diagnostics screen.
public final class RingBufferLogSink: LogSink {
    private struct Buffer {
        var storage: [LogEntry] = []
        var nextIndex = 0
    }

    public let capacity: Int
    private let buffer = Mutex(Buffer())

    public init(capacity: Int = 1_000) {
        self.capacity = max(1, capacity)
    }

    public func record(_ entry: LogEntry) {
        buffer.withLock { buffer in
            if buffer.storage.count < capacity {
                buffer.storage.append(entry)
            } else {
                buffer.storage[buffer.nextIndex] = entry
            }
            buffer.nextIndex = (buffer.nextIndex + 1) % capacity
        }
    }

    /// Entries in chronological order.
    public func snapshot() -> [LogEntry] {
        buffer.withLock { buffer in
            guard buffer.storage.count == capacity else { return buffer.storage }
            return Array(buffer.storage[buffer.nextIndex...] + buffer.storage[..<buffer.nextIndex])
        }
    }

    public func clear() {
        buffer.withLock { $0 = Buffer() }
    }
}

/// Writes formatted entries to standard error. Used by command-line tools and Linux test runs.
public struct ConsoleLogSink: LogSink {
    public init() {}

    public func record(_ entry: LogEntry) {
        var line = "[\(entry.level.label)] \(entry.category): \(entry.message)"
        if !entry.metadata.isEmpty {
            let pairs = entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            line += " {" + pairs.joined(separator: ", ") + "}"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

#if canImport(os)
/// Forwards entries to the unified logging system (Console.app, `log stream`).
public struct UnifiedLogSink: LogSink {
    public let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public func record(_ entry: LogEntry) {
        let logger = os.Logger(subsystem: subsystem, category: entry.category)
        let type: OSLogType
        switch entry.level {
        case .debug: type = .debug
        case .info: type = .info
        case .notice: type = .default
        case .warning: type = .error
        case .error: type = .error
        case .fault: type = .fault
        }
        if entry.metadata.isEmpty {
            logger.log(level: type, "\(entry.message, privacy: .public)")
        } else {
            let pairs = entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logger.log(level: type, "\(entry.message, privacy: .public) {\(pairs, privacy: .private)}")
        }
    }
}
#endif
