import Foundation
import LumenFoundation
import LumenPersistence

/// Remembers which Lumen entities a plugin created on the user's request (the workflow added
/// from one of its templates), so uninstalling the plugin removes them. One entity per
/// contribution.
public struct PluginOwnedEntityStore: Sendable {
    let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func entity(pluginID: String, contributionKey: String) async throws -> PluginOwnedEntity? {
        try await database.read { db in try PluginOwnedEntityRepository.fetch(pluginID: pluginID, contributionKey: contributionKey, in: db) }
    }

    public func entities(of pluginID: String) async throws -> [PluginOwnedEntity] {
        try await database.read { db in try PluginOwnedEntityRepository.fetch(pluginID: pluginID, in: db) }
    }

    /// Records that an installed package's plugin created `entity`.
    public func record(_ entity: PluginOwnedEntity) async throws {
        try await database.write { db in
            guard try PluginPackageRepository.fetch(entity.pluginID, in: db) != nil else {
                throw PluginPackageError.notInstalled(entity.pluginID)
            }
            try PluginOwnedEntityRepository.save(entity, in: db)
        }
    }

    /// Forgets an entity the user deleted themselves.
    public func forget(pluginID: String, contributionKey: String) async throws {
        try await database.write { db in try PluginOwnedEntityRepository.delete(pluginID: pluginID, contributionKey: contributionKey, in: db) }
    }
}
