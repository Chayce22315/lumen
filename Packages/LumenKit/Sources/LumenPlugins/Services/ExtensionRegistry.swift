import Foundation
import Synchronization

/// A typed place where plugins contribute values (assistant tools, automation actions, commands,
/// search sources, dashboard widgets). The application layer declares the points and consumes
/// what was contributed; contributing requires `requiredCapability`.
public struct ExtensionPoint<Contribution: Sendable>: Sendable, Hashable {
    public let id: String
    public let requiredCapability: PluginCapability

    public init(_ id: String, requires capability: PluginCapability) {
        self.id = id
        self.requiredCapability = capability
    }
}

/// A capability-gated service a plugin can ask for (for example a read-only task reader).
public struct ServiceKey<Service: Sendable>: Sendable, Hashable {
    public let id: String
    public let requiredCapability: PluginCapability

    public init(_ id: String, requires capability: PluginCapability) {
        self.id = id
        self.requiredCapability = capability
    }
}

/// Holds every contribution with its owning plugin so a plugin's contributions can be removed
/// atomically when it is deactivated or fails to start.
public final class ExtensionRegistry: Sendable {
    /// `value` is the point's `Contribution`, stored type-erased because one registry serves
    /// points of different types.
    private struct Entry: Sendable {
        let pluginID: String
        let value: any Sendable
    }

    private let entries = Mutex<[String: [Entry]]>([:])
    private let observers = Mutex<[UUID: AsyncStream<String>.Continuation]>([:])

    public init() {}

    func add<C: Sendable>(_ value: C, to point: ExtensionPoint<C>, pluginID: String) {
        entries.withLock { $0[point.id, default: []].append(Entry(pluginID: pluginID, value: value)) }
        notify(point.id)
    }

    /// Values contributed to `point`, in contribution order.
    public func contributions<C: Sendable>(to point: ExtensionPoint<C>) -> [C] {
        entries.withLock { $0[point.id] ?? [] }.compactMap { $0.value as? C }
    }

    /// Values contributed to `point` with the contributing plugin.
    public func contributionsWithOwners<C: Sendable>(to point: ExtensionPoint<C>) -> [(pluginID: String, value: C)] {
        entries.withLock { $0[point.id] ?? [] }.compactMap { entry in
            (entry.value as? C).map { (entry.pluginID, $0) }
        }
    }

    /// Removes everything `pluginID` contributed. Returns the affected point identifiers.
    @discardableResult
    func removeContributions(of pluginID: String) -> Set<String> {
        let changed: Set<String> = entries.withLock { entries in
            var changed = Set<String>()
            for (point, list) in entries {
                let kept = list.filter { $0.pluginID != pluginID }
                if kept.count != list.count {
                    changed.insert(point)
                    entries[point] = kept
                }
            }
            return changed
        }
        for point in changed { notify(point) }
        return changed
    }

    /// Identifiers of points whose contributions changed, as they change.
    public func changes() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in
            _ = self?.observers.withLock { $0.removeValue(forKey: id) }
        }
        observers.withLock { $0[id] = continuation }
        return stream
    }

    private func notify(_ point: String) {
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(point)
        }
    }
}
