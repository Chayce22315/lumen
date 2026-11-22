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
    ])
}
