import Foundation
import LumenPersistence

public enum PluginSchema {
    public static let schema = DatabaseSchema(namespace: "plugins", migrations: [
        .sql("0001_grants", """
            CREATE TABLE plugins_registry (
                plugin_id TEXT PRIMARY KEY NOT NULL,
                granted TEXT NOT NULL DEFAULT '[]',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                updated_at REAL NOT NULL
            );
            """),
        // Third-party packages: the file as received (read again at launch), the key that
        // signed it (pinned for updates), where it came from and the hosts the user allowed.
        // Entities a plugin created on request, so uninstalling removes them. Catalogs the
        // user added, with the entries last fetched.
        .sql("0002_packages", """
            CREATE TABLE plugins_packages (
                plugin_id TEXT PRIMARY KEY NOT NULL,
                version TEXT NOT NULL,
                package BLOB NOT NULL,
                sha256 TEXT NOT NULL,
                publisher_key TEXT,
                source TEXT NOT NULL,
                granted_hosts TEXT NOT NULL DEFAULT '[]',
                installed_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE plugins_owned_entities (
                plugin_id TEXT NOT NULL,
                contribution_key TEXT NOT NULL,
                entity TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (plugin_id, contribution_key)
            );
            CREATE TABLE plugins_catalogs (
                catalog_id TEXT PRIMARY KEY NOT NULL,
                url TEXT NOT NULL UNIQUE,
                name TEXT,
                entries TEXT NOT NULL DEFAULT '[]',
                added_at REAL NOT NULL,
                refreshed_at REAL
            );
            """),
    ])
}
