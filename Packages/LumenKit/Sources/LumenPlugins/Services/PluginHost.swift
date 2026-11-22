import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Loads, permissions and runs plugins.
public actor PluginHost {
    public static let schema = PluginSchema.schema
    public static let hostVersion = PluginVersion(major: 1, minor: 0, patch: 0)
    public static let stateChangedEvent: EventName = "plugins.plugin.stateChanged"

    private struct Registration {
        let plugin: any LumenPlugin
        let isBuiltIn: Bool
        var state: PluginState
    }

    private let database: Database
    private let registry: ExtensionRegistry
    private let services: any PluginServiceProvider
    private let events: EventBus
    private let timeSource: any TimeSource
    private let logging: LoggingSystem
    private let logger: Logger
    private let allowsThirdParty: Bool
    private let activationTimeout: TimeInterval
    private var registrations: [String: Registration] = [:]
    private var order: [String] = []

    public init(
        database: Database,
        registry: ExtensionRegistry,
        services: any PluginServiceProvider,
        events: EventBus,
        timeSource: any TimeSource,
        logging: LoggingSystem,
        allowsThirdParty: Bool,
        activationTimeout: TimeInterval = 5
    ) {
        self.database = database
        self.registry = registry
        self.services = services
        self.events = events
        self.timeSource = timeSource
        self.logging = logging
        self.logger = logging.logger("plugins")
        self.allowsThirdParty = allowsThirdParty
        self.activationTimeout = activationTimeout
    }

    // MARK: - Registration

    /// Makes a plugin known to the host. Built-in plugins are granted their declared capabilities.
    public func register(_ plugin: any LumenPlugin, isBuiltIn: Bool) throws {
        let manifest = plugin.manifest
        let issues = manifest.validationIssues()
        guard issues.isEmpty else { throw PluginError.invalidManifest(issues) }
        guard registrations[manifest.id] == nil else { throw PluginError.duplicatePlugin(manifest.id) }
        registrations[manifest.id] = Registration(plugin: plugin, isBuiltIn: isBuiltIn, state: .inactive)
        order.append(manifest.id)
    }

    /// Removes a third-party plugin and forgets its grants.
    public func uninstall(_ id: String) async throws {
        guard let registration = registrations[id] else { throw PluginError.unknownPlugin(id) }
        guard !registration.isBuiltIn else { throw PluginError.builtInCannotBeRemoved(id) }
        await deactivate(id)
        registrations[id] = nil
        order.removeAll { $0 == id }
        try await database.write { db in try db.execute("DELETE FROM plugins_registry WHERE plugin_id = ?", [id]) }
    }

    // MARK: - Permissions

    public func grant(_ capabilities: Set<PluginCapability>, to id: String) async throws {
        guard let registration = registrations[id] else { throw PluginError.unknownPlugin(id) }
        let allowed = capabilities.intersection(registration.plugin.manifest.capabilities)
        var record = try await storedRecord(id)
        record.granted.formUnion(allowed)
        try await save(record, for: id)
    }

    /// Revokes capabilities; an active plugin is restarted so it loses access immediately.
    public func revoke(_ capabilities: Set<PluginCapability>, from id: String) async throws {
        guard let registration = registrations[id] else { throw PluginError.unknownPlugin(id) }
        var record = try await storedRecord(id)
        record.granted.subtract(capabilities)
        try await save(record, for: id)
        if registration.state.isActive {
            await deactivate(id)
            await activate(id)
        }
    }

    public func setEnabled(_ enabled: Bool, for id: String) async throws {
        guard registrations[id] != nil else { throw PluginError.unknownPlugin(id) }
        var record = try await storedRecord(id)
        record.isEnabled = enabled
        try await save(record, for: id)
        if enabled {
            await activate(id)
        } else {
            await deactivate(id)
            setState(.disabled, for: id)
        }
    }

    // MARK: - Lifecycle

    /// Activates every registered plugin in registration order.
    public func activateAll() async {
        for id in order {
            await activate(id)
        }
    }

    /// Activates one plugin when allowed; the resulting state explains why not otherwise.
    @discardableResult
    public func activate(_ id: String) async -> PluginState {
        guard let registration = registrations[id] else { return .failed("Unknown plugin") }
        if registration.state.isActive { return .active }
        let manifest = registration.plugin.manifest

        guard registration.isBuiltIn || allowsThirdParty else { return setState(.blocked, for: id) }
        guard manifest.minimumHostVersion <= Self.hostVersion else { return setState(.incompatible, for: id) }

        let record: GrantRecord
        do {
            record = try await storedRecord(id)
        } catch {
            logger.error("Plugin grants could not be read", error: error, metadata: ["plugin": id])
            return setState(.failed("Permissions could not be read."), for: id)
        }
        guard record.isEnabled else { return setState(.disabled, for: id) }
        let granted = registration.isBuiltIn ? manifest.capabilities : record.granted
        let missing = manifest.capabilities.subtracting(granted)
        guard missing.isEmpty else { return setState(.needsPermission(missing), for: id) }

        let context = PluginContext(
            pluginID: id,
            declared: manifest.capabilities,
            granted: granted,
            registry: registry,
            services: services,
            logger: logging.logger("plugin.\(id)")
        )
        let plugin = registration.plugin
        let timeout = activationTimeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await plugin.activate(context) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw PluginError.activationTimedOut(id)
                }
                try await group.next()
                group.cancelAll()
            }
            return setState(.active, for: id)
        } catch {
            registry.removeContributions(of: id)
            logger.error("Plugin activation failed", error: error, metadata: ["plugin": id])
            return setState(.failed(ErrorPresentation.from(error).message), for: id)
        }
    }

    public func deactivate(_ id: String) async {
        guard let registration = registrations[id], registration.state.isActive else { return }
        await registration.plugin.deactivate()
        registry.removeContributions(of: id)
        setState(.inactive, for: id)
    }

    public func deactivateAll() async {
        for id in order.reversed() {
            await deactivate(id)
        }
    }

    // MARK: - Inspection

    public func statuses() async -> [PluginStatus] {
        var result: [PluginStatus] = []
        for id in order {
            guard let registration = registrations[id] else { continue }
            let granted: Set<PluginCapability>
            if registration.isBuiltIn {
                granted = registration.plugin.manifest.capabilities
            } else {
                granted = (try? await storedRecord(id).granted) ?? []
            }
            result.append(PluginStatus(manifest: registration.plugin.manifest, isBuiltIn: registration.isBuiltIn, state: registration.state, grantedCapabilities: granted))
        }
        return result
    }

    public func state(of id: String) -> PluginState? {
        registrations[id]?.state
    }

    // MARK: - Private

    @discardableResult
    private func setState(_ state: PluginState, for id: String) -> PluginState {
        guard var registration = registrations[id] else { return state }
        let changed = registration.state != state
        registration.state = state
        registrations[id] = registration
        if changed {
            events.publish(DomainEvent(name: Self.stateChangedEvent, attributes: ["plugin": .string(id)], actor: .system, occurredAt: timeSource.now()))
        }
        return state
    }

    private struct GrantRecord: Sendable {
        var granted: Set<PluginCapability>
        var isEnabled: Bool
    }

    private func storedRecord(_ id: String) async throws -> GrantRecord {
        try await database.read { db in
            guard let row = try db.queryFirst("SELECT * FROM plugins_registry WHERE plugin_id = ?", [id]) else {
                return GrantRecord(granted: [], isEnabled: true)
            }
            let raw: [String] = try row.json("granted")
            return GrantRecord(granted: Set(raw.compactMap(PluginCapability.init(rawValue:))), isEnabled: try row.get("is_enabled"))
        }
    }

    private func save(_ record: GrantRecord, for id: String) async throws {
        let now = timeSource.now()
        let granted = record.granted.map(\.rawValue).sorted()
        let enabled = record.isEnabled
        try await database.write { db in
            try db.execute(
                """
                INSERT INTO plugins_registry (plugin_id, granted, is_enabled, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(plugin_id) DO UPDATE SET granted = excluded.granted, is_enabled = excluded.is_enabled, updated_at = excluded.updated_at
                """,
                [id, JSONColumn(granted), enabled, now]
            )
        }
    }
}
