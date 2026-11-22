import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Something the user did on a widget that the app must carry out. The widget extension never
/// opens the database; it records the request here and the app applies it when it next runs.
public struct WidgetAction: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case completeTask
    }

    public let id: UUID
    public let kind: Kind
    public let taskID: UUID
    public let requestedAt: Date

    public init(id: UUID = UUID(), kind: Kind, taskID: UUID, requestedAt: Date) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.requestedAt = requestedAt
    }
}

public enum WidgetActionQueueError: Error, Equatable {
    /// The lock file could not be opened or locked (`errno`).
    case lockFailed(Int32)
}

/// A small file of pending widget actions, shared by the widget extension (which appends) and the
/// app (which removes what it applied). Every read-modify-write holds an exclusive `flock` on a
/// sibling lock file, so the two processes never lose each other's changes, and writes are atomic.
public struct WidgetActionQueue: Sendable {
    /// More pending actions than this means the app has not run for a long time; the oldest go.
    public static let capacity = 50

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(directory: URL) {
        self.url = directory.appendingPathComponent(SharedContainer.actionQueueFileName)
    }

    /// Appends `action` unless the same kind of action for the same task is already pending.
    /// Returns whether it was added.
    @discardableResult
    public func enqueue(_ action: WidgetAction) throws -> Bool {
        try withLock {
            var actions = try load()
            guard !actions.contains(where: { $0.kind == action.kind && $0.taskID == action.taskID }) else { return false }
            actions.append(action)
            if actions.count > Self.capacity {
                actions.removeFirst(actions.count - Self.capacity)
            }
            try store(actions)
            return true
        }
    }

    /// Pending actions, oldest first.
    public func pending() throws -> [WidgetAction] {
        try withLock { try load() }
    }

    /// Removes the actions the app has dealt with. Actions added meanwhile are kept.
    public func remove(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            let actions = try load()
            let remaining = actions.filter { !ids.contains($0.id) }
            guard remaining.count != actions.count else { return }
            try store(remaining)
        }
    }

    // MARK: - File format

    private struct File: Codable {
        var version: Int
        var actions: [WidgetAction]
    }

    private static let version = 1

    private func load() throws -> [WidgetAction] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // An unreadable or future-format file holds nothing this build can apply; it is replaced on
        // the next write rather than blocking every later widget action.
        guard let file = try? decoder.decode(File.self, from: data), file.version == Self.version else { return [] }
        return file.actions
    }

    private func store(_ actions: [WidgetAction]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(File(version: Self.version, actions: actions))
        try data.write(to: url, options: [.atomic])
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw WidgetActionQueueError.lockFailed(errno) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw WidgetActionQueueError.lockFailed(errno) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
