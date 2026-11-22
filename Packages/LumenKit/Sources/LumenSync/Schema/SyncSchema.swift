import Foundation
import LumenPersistence

public enum SyncSchema {
    public static let schema = DatabaseSchema(namespace: "sync", migrations: [
        .sql("0001_sync_bookkeeping", """
            CREATE TABLE sync_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );

            CREATE TABLE sync_shadows (
                entity_kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (entity_kind, entity_id)
            );

            CREATE TABLE sync_conflicts (
                id TEXT PRIMARY KEY NOT NULL,
                entity_kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                fields TEXT NOT NULL,
                detected_at REAL NOT NULL,
                reviewed_at REAL
            );
            CREATE INDEX sync_conflicts_reviewed ON sync_conflicts (reviewed_at, detected_at DESC);

            CREATE TABLE sync_runs (
                id TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                outcome TEXT NOT NULL,
                pushed INTEGER NOT NULL,
                pulled INTEGER NOT NULL,
                conflicts INTEGER NOT NULL,
                error_message TEXT
            );
            CREATE INDEX sync_runs_started ON sync_runs (started_at DESC);
            """),
        .sql("0002_blob_uploads", """
            CREATE TABLE sync_blobs (
                sha256 TEXT PRIMARY KEY NOT NULL,
                uploaded_at REAL NOT NULL
            );
            """),
    ])
}
