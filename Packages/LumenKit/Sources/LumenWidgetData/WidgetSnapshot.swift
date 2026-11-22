import Foundation

/// What the widget extension renders. The app writes it to the shared App Group container
/// whenever the underlying data changes; the extension only reads it, so it never opens the
/// database or links the engines.
public struct WidgetSnapshot: Sendable, Hashable, Codable {
    public struct TaskLine: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let title: String
        /// `HH:MM` when the task has a due time.
        public let dueTime: String?
        public let isOverdue: Bool
        public let priority: Int

        public init(id: UUID, title: String, dueTime: String?, isOverdue: Bool, priority: Int) {
            self.id = id
            self.title = title
            self.dueTime = dueTime
            self.isOverdue = isOverdue
            self.priority = priority
        }
    }

    public struct EventLine: Sendable, Hashable, Codable {
        public let title: String
        public let start: Date
        public let end: Date
        public let location: String

        public init(title: String, start: Date, end: Date, location: String) {
            self.title = title
            self.start = start
            self.end = end
            self.location = location
        }
    }

    public struct ProjectLine: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let name: String
        public let fractionComplete: Double
        /// Identity color name (`IdentityColor` raw value).
        public let color: String

        public init(id: UUID, name: String, fractionComplete: Double, color: String) {
            self.id = id
            self.name = name
            self.fractionComplete = fractionComplete
            self.color = color
        }
    }

    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let dueToday: Int
    public let overdue: Int
    public let completedToday: Int
    public let tasks: [TaskLine]
    public let nextEvent: EventLine?
    public let projects: [ProjectLine]

    public init(generatedAt: Date, dueToday: Int, overdue: Int, completedToday: Int, tasks: [TaskLine], nextEvent: EventLine?, projects: [ProjectLine]) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.dueToday = dueToday
        self.overdue = overdue
        self.completedToday = completedToday
        self.tasks = tasks
        self.nextEvent = nextEvent
        self.projects = projects
    }

    /// Shown before the app has run for the first time. Contains no data, only zeros.
    public static func empty(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: date, dueToday: 0, overdue: 0, completedToday: 0, tasks: [], nextEvent: nil, projects: [])
    }
}

/// Reads and writes the snapshot file atomically.
public struct WidgetSnapshotStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// The stored snapshot, or `nil` when none was written yet or it is from an incompatible version.
    public func read() throws -> WidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
        return snapshot.version == WidgetSnapshot.currentVersion ? snapshot : nil
    }
}

/// Where the app and its widget extension share data.
public enum SharedContainer {
    /// The App Group both targets declare in their entitlements.
    public static let appGroupIdentifier = "group.app.lumen"

    /// The shared data directory, or `nil` when the App Group is not provisioned (for example an
    /// unsigned simulator build); callers then fall back to the app's own container.
    public static func directory() -> URL? {
        #if canImport(Darwin)
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Lumen", isDirectory: true)
        #else
        nil
        #endif
    }

    /// The app's private data directory, used when the App Group is unavailable.
    public static func fallbackDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumen", isDirectory: true)
    }

    public static var snapshotFileName: String { "WidgetSnapshot.json" }
}
