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
        /// Due today (and so counted in `dueToday`).
        public let isDueToday: Bool
        /// Checked on the widget; the app completes it the next time it runs.
        public let isCompleted: Bool

        public init(id: UUID, title: String, dueTime: String?, isOverdue: Bool, priority: Int, isDueToday: Bool = false, isCompleted: Bool = false) {
            self.id = id
            self.title = title
            self.dueTime = dueTime
            self.isOverdue = isOverdue
            self.priority = priority
            self.isDueToday = isDueToday
            self.isCompleted = isCompleted
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, dueTime, isOverdue, priority, isDueToday, isCompleted
        }

        /// Snapshots written before `isDueToday` and `isCompleted` existed decode with `false`.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.title = try c.decode(String.self, forKey: .title)
            self.dueTime = try c.decodeIfPresent(String.self, forKey: .dueTime)
            self.isOverdue = try c.decode(Bool.self, forKey: .isOverdue)
            self.priority = try c.decode(Int.self, forKey: .priority)
            self.isDueToday = try c.decodeIfPresent(Bool.self, forKey: .isDueToday) ?? false
            self.isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        }

        func completed() -> TaskLine {
            TaskLine(id: id, title: title, dueTime: dueTime, isOverdue: isOverdue, priority: priority, isDueToday: isDueToday, isCompleted: true)
        }
    }

    /// Today's progress for the lock-screen ring: done versus still due (including overdue).
    public struct TodayProgress: Sendable, Hashable {
        public let completed: Int
        public let remaining: Int

        public init(completed: Int, remaining: Int) {
            self.completed = completed
            self.remaining = remaining
        }

        public var total: Int { completed + remaining }
        /// 0…1; 0 when nothing was due or done.
        public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
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

    public var todayProgress: TodayProgress {
        TodayProgress(completed: max(0, completedToday), remaining: max(0, dueToday) + max(0, overdue))
    }

    /// The first task not yet checked, for the lock-screen widgets.
    public var nextOpenTask: TaskLine? {
        tasks.first { !$0.isCompleted }
    }

    /// The snapshot as it will look once the app has completed `taskID`: the line is checked and
    /// the counts move, so the widget responds at once. Unknown or checked tasks change nothing.
    public func markingCompleted(_ taskID: UUID) -> WidgetSnapshot {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), !tasks[index].isCompleted else { return self }
        let line = tasks[index]
        var lines = tasks
        lines[index] = line.completed()
        return WidgetSnapshot(
            generatedAt: generatedAt,
            dueToday: line.isDueToday && !line.isOverdue ? max(0, dueToday - 1) : dueToday,
            overdue: line.isOverdue ? max(0, overdue - 1) : overdue,
            completedToday: completedToday + 1,
            tasks: lines,
            nextEvent: nextEvent,
            projects: projects
        )
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
    /// Info.plist key carrying the App Group identifier. Both targets set it from the
    /// `LUMEN_APP_GROUP` build setting (`App/Configuration/Lumen.xcconfig`), which also feeds
    /// their entitlements, so a personal bundle prefix changes all three together.
    public static let appGroupInfoKey = "LumenAppGroupIdentifier"
    /// Used when the running bundle doesn't name one (tests, tools).
    public static let defaultAppGroupIdentifier = "group.app.lumen"

    /// The App Group both targets declare in their entitlements.
    public static var appGroupIdentifier: String {
        appGroupIdentifier(in: Bundle.main.infoDictionary ?? [:])
    }

    /// The identifier named by an Info.plist dictionary, or the default when it names none.
    public static func appGroupIdentifier(in infoDictionary: [String: Any]) -> String {
        guard let value = infoDictionary[appGroupInfoKey] as? String else { return defaultAppGroupIdentifier }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded "$(…)" means the build setting was missing; treat it as unset.
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? defaultAppGroupIdentifier : trimmed
    }

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
    public static var actionQueueFileName: String { "WidgetActions.json" }
}
