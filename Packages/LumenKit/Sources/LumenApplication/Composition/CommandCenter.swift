import Foundation
import Synchronization
import LumenPlugins
import LumenSearch

/// Resolves palette commands to actions and keeps the searchable command list in step with what
/// features and plugins contributed.
public final class CommandCenter: Sendable {
    public let registry: CommandRegistry
    private let actions = Mutex<[String: CommandAction]>([:])

    public init(registry: CommandRegistry) {
        self.registry = registry
    }

    /// Replaces the command set with the current contributions.
    func reload(from extensions: ExtensionRegistry) {
        let contributed = extensions.contributions(to: LumenExtensionPoints.commands)
        let previous = registry.all.map(\.id)
        for id in previous { registry.unregister(id: id) }
        var map: [String: CommandAction] = [:]
        for item in contributed where map[item.command.id] == nil {
            registry.register(item.command)
            map[item.command.id] = item.action
        }
        actions.withLock { $0 = map }
    }

    public func action(for id: String) -> CommandAction? {
        actions.withLock { $0[id] }
    }
}
