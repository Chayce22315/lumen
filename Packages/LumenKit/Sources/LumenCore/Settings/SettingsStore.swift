import Foundation
import Synchronization
import LumenFoundation
import LumenPersistence

/// Device-local preferences, persisted in SQLite and cached in memory.
///
/// Settings are deliberately not synchronized: they describe this device (layout, model choice,
/// notification preferences). Values that must follow the user across devices belong in a domain
/// entity instead.
public final class SettingsStore: Sendable {
    public static let changedEvent: EventName = "core.setting.changed"

    public static let schema = DatabaseSchema(namespace: "core.settings", migrations: [
        .sql("0001_settings", """
            CREATE TABLE core_settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """),
    ])

    private let database: Database
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logger: Logger
    private let cache = Mutex<[String: JSONValue]>([:])

    public init(database: Database, events: EventBus, timeSource: any TimeSource, logger: Logger) {
        self.database = database
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
    }

    /// The stored value, or the key's default when unset or unreadable (an unreadable value is logged).
    public func value<Value>(_ key: SettingKey<Value>) async -> Value {
        do {
            guard let stored = try await storedValue(named: key.name) else { return key.defaultValue }
            return try stored.decode(as: Value.self)
        } catch {
            logger.warning("Setting could not be read; using default", metadata: ["key": key.name, "error": String(describing: error)])
            return key.defaultValue
        }
    }

    public func set<Value>(_ value: Value, for key: SettingKey<Value>) async throws {
        let json = try JSONValue(encoding: value)
        let text = try json.compactString()
        let now = timeSource.now()
        try await database.write { db in
            try db.execute(
                """
                INSERT INTO core_settings (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                [key.name, text, now]
            )
        }
        cache.withLock { $0[key.name] = json }
        events.publish(DomainEvent(name: Self.changedEvent, attributes: ["key": .string(key.name)], actor: .user, occurredAt: now))
    }

    /// Removes the stored value so the default applies again.
    public func reset<Value>(_ key: SettingKey<Value>) async throws {
        try await database.write { db in
            try db.execute("DELETE FROM core_settings WHERE key = ?", [key.name])
        }
        cache.withLock { $0[key.name] = nil }
        events.publish(DomainEvent(name: Self.changedEvent, attributes: ["key": .string(key.name)], actor: .user, occurredAt: timeSource.now()))
    }

    private func storedValue(named name: String) async throws -> JSONValue? {
        if let cached = cache.withLock({ $0[name] }) {
            return cached
        }
        let text: String? = try await database.read { db in
            try db.scalar("SELECT value FROM core_settings WHERE key = ?", [name])
        }
        guard let text else { return nil }
        let value = try JSONValue(parsing: text)
        cache.withLock { $0[name] = value }
        return value
    }
}
