import Foundation
import Synchronization
import LumenFoundation

/// Resolves capability-gated services. Implemented by the application layer.
public protocol PluginServiceProvider: Sendable {
    /// The service for `id`, or `nil` when Lumen does not offer it to plugins.
    func service(id: String, for pluginID: String) -> (any Sendable)?
}

/// Everything a plugin can do, checked against the capabilities the user granted.
///
/// A plugin receives its own context; it can only contribute to points and use services whose
/// capability it both declared in its manifest and was granted.
public final class PluginContext: Sendable {
    public let pluginID: String
    public let logger: Logger
    private let declared: Set<PluginCapability>
    private let granted: Set<PluginCapability>
    private let registry: ExtensionRegistry
    private let services: any PluginServiceProvider

    init(
        pluginID: String,
        declared: Set<PluginCapability>,
        granted: Set<PluginCapability>,
        registry: ExtensionRegistry,
        services: any PluginServiceProvider,
        logger: Logger
    ) {
        self.pluginID = pluginID
        self.declared = declared
        self.granted = granted
        self.registry = registry
        self.services = services
        self.logger = logger
    }

    public func has(_ capability: PluginCapability) -> Bool {
        declared.contains(capability) && granted.contains(capability)
    }

    public func require(_ capability: PluginCapability) throws {
        guard declared.contains(capability) else {
            throw PluginError.undeclaredCapability(plugin: pluginID, capability: capability)
        }
        guard granted.contains(capability) else {
            throw PluginError.permissionDenied(plugin: pluginID, capability: capability)
        }
    }

    public func contribute<C: Sendable>(_ value: C, to point: ExtensionPoint<C>) throws {
        try require(point.requiredCapability)
        registry.add(value, to: point, pluginID: pluginID)
    }

    public func service<S: Sendable>(_ key: ServiceKey<S>) throws -> S {
        try require(key.requiredCapability)
        guard let service = services.service(id: key.id, for: pluginID) as? S else {
            throw PluginError.serviceUnavailable(key.id)
        }
        return service
    }
}

/// A unit of functionality loaded into Lumen. Built-in features use the same protocol as
/// third-party plugins.
public protocol LumenPlugin: Sendable {
    var manifest: PluginManifest { get }
    /// Registers contributions. Throwing (or timing out) rolls back everything it contributed.
    func activate(_ context: PluginContext) async throws
    /// Releases resources. Contributions are removed by the host.
    func deactivate() async
}

extension LumenPlugin {
    public func deactivate() async {}
}
