import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The assistant's long-term memory: short facts the user (or the assistant, when asked) saved.
///
/// Memories are synchronized entities. A global switch (`AssistantSettings.memoryEnabled`)
/// controls whether they are used at all; each memory can also be disabled individually.
public final class MemoryStore: Sendable {
    public static let maximumLength = 1_000

    private let database: Database
    private let events: EventBus
    private let settings: SettingsStore
    private let timeSource: any TimeSource
    private let logger: Logger

    public init(database: Database, events: EventBus, settings: SettingsStore, timeSource: any TimeSource, logger: Logger) {
        self.database = database
        self.events = events
        self.settings = settings
        self.timeSource = timeSource
        self.logger = logger
    }

    // MARK: - Global switch

    public func isMemoryEnabled() async -> Bool {
        await settings.value(AssistantSettings.memoryEnabled)
    }

    public func setMemoryEnabled(_ enabled: Bool) async throws {
        try await settings.set(enabled, for: AssistantSettings.memoryEnabled)
    }

    // MARK: - Reading

    /// All memories, oldest first.
    public func memories(includeDisabled: Bool = true) async throws -> [MemoryItem] {
        try await database.read { db in try MemoryRepository.all(includeDisabled: includeDisabled, in: db) }
    }

    /// What the assistant may use right now: enabled memories, or nothing when memory is off.
    public func activeMemories() async throws -> [MemoryItem] {
        guard await isMemoryEnabled() else { return [] }
        return try await memories(includeDisabled: false)
    }

    public func memory(_ id: MemoryItem.ID) async throws -> MemoryItem? {
        try await database.read { db in try MemoryRepository.fetch(id, in: db) }
    }

    // MARK: - Writing

    @discardableResult
    public func add(_ content: String, source: MemorySource = .user, context: ActionContext = .user) async throws -> MemoryItem {
        let text = try Self.validate(content)
        let memory = MemoryItem(content: text, source: source, createdAt: timeSource.now())
        try await database.write { db in try MemoryRepository.save(memory, in: db) }
        events.publish(context.event(IntelligenceEvents.memoryAdded, entity: memory.reference, attributes: ["source": .string(source.rawValue)], at: memory.createdAt))
        logger.info("Memory added", metadata: ["source": source.rawValue])
        return memory
    }

    @discardableResult
    public func update(_ id: MemoryItem.ID, content: String, context: ActionContext = .user) async throws -> MemoryItem {
        let text = try Self.validate(content)
        return try await modify(id, context: context, attributes: ["field": "content"]) { $0.content = text }
    }

    @discardableResult
    public func setEnabled(_ isEnabled: Bool, for id: MemoryItem.ID, context: ActionContext = .user) async throws -> MemoryItem {
        try await modify(id, context: context, attributes: ["field": "isEnabled", "isEnabled": .bool(isEnabled)]) { $0.isEnabled = isEnabled }
    }

    public func delete(_ id: MemoryItem.ID, context: ActionContext = .user) async throws {
        let existed = try await database.write { db -> Bool in
            guard try MemoryRepository.fetch(id, in: db) != nil else { return false }
            try MemoryRepository.delete(id, in: db)
            return true
        }
        guard existed else { throw DatabaseError.notFound(EntityReference(kind: .memory, id: id)) }
        events.publish(context.event(IntelligenceEvents.memoryDeleted, entity: EntityReference(kind: .memory, id: id), at: timeSource.now()))
    }

    /// Deletes every memory (each deletion is recorded for sync and published).
    public func clearAll(context: ActionContext = .user) async throws {
        let ids = try await database.write { db -> [MemoryItem.ID] in
            let all = try MemoryRepository.all(includeDisabled: true, in: db)
            for memory in all {
                try MemoryRepository.delete(memory.id, in: db)
            }
            return all.map(\.id)
        }
        let now = timeSource.now()
        for id in ids {
            events.publish(context.event(IntelligenceEvents.memoryDeleted, entity: EntityReference(kind: .memory, id: id), at: now))
        }
        logger.info("Memories cleared", metadata: ["count": String(ids.count)])
    }

    private func modify(
        _ id: MemoryItem.ID,
        context: ActionContext,
        attributes: [String: JSONValue],
        _ change: @escaping @Sendable (inout MemoryItem) -> Void
    ) async throws -> MemoryItem {
        let now = timeSource.now()
        let updated = try await database.write { db -> MemoryItem? in
            guard var memory = try MemoryRepository.fetch(id, in: db) else { return nil }
            change(&memory)
            memory.updatedAt = now
            try MemoryRepository.save(memory, in: db)
            return memory
        }
        guard let updated else { throw DatabaseError.notFound(EntityReference(kind: .memory, id: id)) }
        events.publish(context.event(IntelligenceEvents.memoryUpdated, entity: updated.reference, attributes: attributes, at: now))
        return updated
    }

    static func validate(_ content: String) throws -> String {
        guard let text = content.nonBlank else {
            throw ValidationError(field: "memory", reason: "A memory can't be empty.")
        }
        guard text.count <= maximumLength else {
            throw ValidationError(field: "memory", reason: "Keep memories under \(maximumLength) characters.")
        }
        return text
    }
}
