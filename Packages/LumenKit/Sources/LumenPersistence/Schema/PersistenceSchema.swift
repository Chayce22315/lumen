import Foundation

/// Tables owned by the persistence layer itself: replica identity and the change log.
enum PersistenceSchema {
    static let schema = DatabaseSchema(namespace: "persistence", migrations: [
        .sql("0001_replica_and_change_log", """
            CREATE TABLE lumen_replica (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );

            CREATE TABLE lumen_changes (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                entity_kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
                payload TEXT,
                timestamp TEXT NOT NULL,
                origin TEXT NOT NULL CHECK (origin IN ('local', 'remote')),
                recorded_at REAL NOT NULL
            );

            CREATE INDEX lumen_changes_entity ON lumen_changes (entity_kind, entity_id, sequence);
            CREATE INDEX lumen_changes_origin ON lumen_changes (origin, sequence);
            """),
    ])
}
