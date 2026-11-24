import Foundation
import LumenPersistence

public enum SearchSchema {
    public static let schema = DatabaseSchema(namespace: "search", migrations: [
        .sql("0001_index_and_history", """
            CREATE VIRTUAL TABLE search_fts USING fts5(
                title,
                body,
                tags,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TABLE search_entries (
                entity_kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                fts_rowid INTEGER NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT NOT NULL,
                tags TEXT NOT NULL,
                updated_at REAL NOT NULL,
                boost REAL NOT NULL DEFAULT 1,
                PRIMARY KEY (entity_kind, entity_id)
            );
            CREATE UNIQUE INDEX search_entries_rowid ON search_entries (fts_rowid);

            CREATE TABLE search_history (
                normalized TEXT PRIMARY KEY NOT NULL,
                query TEXT NOT NULL,
                last_used REAL NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 1
            );
            """),
    ])
}
