import Foundation
import LumenPersistence

/// Tables owned by the knowledge engine. Hand `KnowledgeSchema.schema` to `Database.migrate`.
///
/// No foreign keys: synchronized rows can arrive in any order (a note before its collection), so
/// referential cleanup is done explicitly by the repositories and services.
public enum KnowledgeSchema {
    public static let namespace = "knowledge"

    public static let schema = DatabaseSchema(namespace: namespace, migrations: [
        .sql("0001_notes_collections_documents_versions_links", """
            CREATE TABLE knowledge_collections (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                parent_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                symbol_name TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX knowledge_collections_parent ON knowledge_collections (parent_id, sort_order);

            CREATE TABLE knowledge_notes (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                title_key TEXT NOT NULL,
                body TEXT NOT NULL,
                collection_id TEXT,
                tags TEXT NOT NULL DEFAULT '[]',
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX knowledge_notes_updated ON knowledge_notes (updated_at DESC);
            CREATE INDEX knowledge_notes_collection ON knowledge_notes (collection_id);
            CREATE INDEX knowledge_notes_title_key ON knowledge_notes (title_key, updated_at DESC);

            CREATE TABLE knowledge_documents (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                title_key TEXT NOT NULL,
                original_file_name TEXT NOT NULL,
                content_type TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                storage_key TEXT NOT NULL,
                collection_id TEXT,
                tags TEXT NOT NULL DEFAULT '[]',
                extracted_text TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX knowledge_documents_sha256 ON knowledge_documents (sha256);
            CREATE INDEX knowledge_documents_storage_key ON knowledge_documents (storage_key);
            CREATE INDEX knowledge_documents_collection ON knowledge_documents (collection_id);
            CREATE INDEX knowledge_documents_updated ON knowledge_documents (updated_at DESC);

            CREATE TABLE knowledge_note_versions (
                id TEXT PRIMARY KEY NOT NULL,
                note_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                saved_at REAL NOT NULL
            );
            CREATE INDEX knowledge_note_versions_note ON knowledge_note_versions (note_id, saved_at DESC);

            CREATE TABLE knowledge_links (
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                target_kind TEXT,
                target_id TEXT,
                target_title TEXT NOT NULL,
                target_title_key TEXT NOT NULL,
                label TEXT,
                kind TEXT NOT NULL CHECK (kind IN ('wikiLink', 'entityMention')),
                PRIMARY KEY (source_kind, source_id, position)
            );
            CREATE INDEX knowledge_links_target ON knowledge_links (target_kind, target_id);
            CREATE INDEX knowledge_links_target_title ON knowledge_links (target_title_key);
            """),
    ])
}
