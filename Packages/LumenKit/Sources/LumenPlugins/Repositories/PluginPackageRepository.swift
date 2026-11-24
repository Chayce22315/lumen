import Foundation
import LumenFoundation
import LumenPersistence

/// An installed package as stored: the file is decoded and its signature checked again on read
/// (`PluginPackageManager`), so a stored row is never trusted blindly.
struct StoredPluginPackage: Sendable, Hashable {
    let pluginID: String
    let version: String
    let data: Data
    let sha256: String
    /// Base64 of the key that signed the installed version.
    let publisherKey: String?
    let source: PluginSource
    let grantedHosts: Set<String>
    let installedAt: Date
    let updatedAt: Date
}

/// SQL for `plugins_packages`. Device-local: plugins are installed per device, so rows have no
/// change records.
enum PluginPackageRepository {
    static func fetchAll(in db: DatabaseConnection) throws -> [StoredPluginPackage] {
        try db.query("SELECT * FROM plugins_packages ORDER BY installed_at, plugin_id").map(stored)
    }

    static func fetch(_ id: String, in db: DatabaseConnection) throws -> StoredPluginPackage? {
        try db.queryFirst("SELECT * FROM plugins_packages WHERE plugin_id = ?", [id]).map(stored)
    }

    static func save(_ package: StoredPluginPackage, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO plugins_packages (plugin_id, version, package, sha256, publisher_key, source, granted_hosts, installed_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(plugin_id) DO UPDATE SET
                version = excluded.version, package = excluded.package, sha256 = excluded.sha256,
                publisher_key = excluded.publisher_key, source = excluded.source,
                granted_hosts = excluded.granted_hosts, updated_at = excluded.updated_at
            """,
            [
                package.pluginID, package.version, package.data, package.sha256, package.publisherKey,
                JSONColumn(package.source), JSONColumn(package.grantedHosts.sorted()), package.installedAt, package.updatedAt,
            ]
        )
    }

    static func setGrantedHosts(_ hosts: Set<String>, for id: String, at date: Date, in db: DatabaseConnection) throws {
        try db.execute("UPDATE plugins_packages SET granted_hosts = ?, updated_at = ? WHERE plugin_id = ?", [JSONColumn(hosts.sorted()), date, id])
    }

    static func delete(_ id: String, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM plugins_packages WHERE plugin_id = ?", [id])
    }

    private static func stored(_ row: Row) throws -> StoredPluginPackage {
        let hosts: [String] = try row.json("granted_hosts")
        return StoredPluginPackage(
            pluginID: try row.get("plugin_id"),
            version: try row.get("version"),
            data: try row.get("package"),
            sha256: try row.get("sha256"),
            publisherKey: try row.get("publisher_key"),
            source: try row.json("source"),
            grantedHosts: Set(hosts),
            installedAt: try row.get("installed_at"),
            updatedAt: try row.get("updated_at")
        )
    }
}

/// SQL for `plugins_owned_entities`.
enum PluginOwnedEntityRepository {
    static func fetch(pluginID: String, in db: DatabaseConnection) throws -> [PluginOwnedEntity] {
        try db.query("SELECT * FROM plugins_owned_entities WHERE plugin_id = ? ORDER BY created_at", [pluginID]).compactMap(owned)
    }

    static func fetch(pluginID: String, contributionKey: String, in db: DatabaseConnection) throws -> PluginOwnedEntity? {
        try db.queryFirst("SELECT * FROM plugins_owned_entities WHERE plugin_id = ? AND contribution_key = ?", [pluginID, contributionKey]).flatMap(owned)
    }

    static func save(_ entity: PluginOwnedEntity, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO plugins_owned_entities (plugin_id, contribution_key, entity, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(plugin_id, contribution_key) DO UPDATE SET entity = excluded.entity, created_at = excluded.created_at
            """,
            [entity.pluginID, entity.contributionKey, entity.entity.uri, entity.createdAt]
        )
    }

    static func delete(pluginID: String, contributionKey: String, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM plugins_owned_entities WHERE plugin_id = ? AND contribution_key = ?", [pluginID, contributionKey])
    }

    static func deleteAll(pluginID: String, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM plugins_owned_entities WHERE plugin_id = ?", [pluginID])
    }

    /// `nil` for a row whose entity reference no longer parses (written by a future version);
    /// such a row is skipped and removed with the plugin.
    private static func owned(_ row: Row) throws -> PluginOwnedEntity? {
        let uri: String = try row.get("entity")
        guard let reference = EntityReference(uri: uri) else { return nil }
        return PluginOwnedEntity(pluginID: try row.get("plugin_id"), contributionKey: try row.get("contribution_key"), entity: reference, createdAt: try row.get("created_at"))
    }
}

/// SQL for `plugins_catalogs`.
enum PluginCatalogRepository {
    static func fetchAll(in db: DatabaseConnection) throws -> [PluginCatalog] {
        try db.query("SELECT * FROM plugins_catalogs ORDER BY added_at, catalog_id").map(catalog)
    }

    static func fetch(_ id: PluginCatalog.ID, in db: DatabaseConnection) throws -> PluginCatalog? {
        try db.queryFirst("SELECT * FROM plugins_catalogs WHERE catalog_id = ?", [id]).map(catalog)
    }

    static func exists(url: URL, in db: DatabaseConnection) throws -> Bool {
        try db.queryFirst("SELECT catalog_id FROM plugins_catalogs WHERE url = ?", [url.absoluteString]) != nil
    }

    static func save(_ catalog: PluginCatalog, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO plugins_catalogs (catalog_id, url, name, entries, added_at, refreshed_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(catalog_id) DO UPDATE SET name = excluded.name, entries = excluded.entries, refreshed_at = excluded.refreshed_at
            """,
            [catalog.id, catalog.url.absoluteString, catalog.name, JSONColumn(catalog.entries), catalog.addedAt, catalog.refreshedAt]
        )
    }

    static func delete(_ id: PluginCatalog.ID, in db: DatabaseConnection) throws -> Bool {
        try db.execute("DELETE FROM plugins_catalogs WHERE catalog_id = ?", [id])
        return db.changes > 0
    }

    private static func catalog(_ row: Row) throws -> PluginCatalog {
        let text: String = try row.get("url")
        guard let url = URL(string: text) else { throw DatabaseError.typeMismatch(column: "url", expected: "URL", actual: "text") }
        return PluginCatalog(
            id: try row.get("catalog_id"),
            url: url,
            name: try row.get("name"),
            entries: try row.json("entries"),
            addedAt: try row.get("added_at"),
            refreshedAt: try row.get("refreshed_at")
        )
    }
}
