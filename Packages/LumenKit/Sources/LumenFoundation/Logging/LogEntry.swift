import Foundation

public enum LogLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .fault: return "fault"
        }
    }
}

/// One log line. Messages must describe what the system did, never contain user content
/// (note bodies, prompts, task titles): entries are retained for the diagnostics screen.
public struct LogEntry: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        date: Date,
        level: LogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

/// Destination for log entries.
public protocol LogSink: Sendable {
    func record(_ entry: LogEntry)
}
