import Foundation
import LumenPersistence

/// Tables owned by the intelligence engine.
///
/// Conversations, messages and memories are synchronized (every repository `save`/`delete`
/// writes a change record in the same transaction). Usage is device-local. There are no foreign
/// keys between the synchronized tables so the sync engine can apply records in any order;
/// the repositories keep them consistent.
public enum IntelligenceSchema {
    public static let schema = DatabaseSchema(namespace: "intelligence", migrations: [
        .sql("0001_conversations_messages_memories_usage", """
            CREATE TABLE intelligence_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                provider_id TEXT,
                model_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_archived INTEGER NOT NULL DEFAULT 0,
                is_pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX intelligence_conversations_list
                ON intelligence_conversations (is_archived, is_pinned DESC, updated_at DESC);

            CREATE TABLE intelligence_messages (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                blocks TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                usage TEXT,
                error_message TEXT,
                provider_id TEXT,
                model_id TEXT
            );
            CREATE INDEX intelligence_messages_conversation
                ON intelligence_messages (conversation_id, created_at);

            CREATE TABLE intelligence_memories (
                id TEXT PRIMARY KEY NOT NULL,
                content TEXT NOT NULL,
                source TEXT NOT NULL,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE intelligence_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                conversation_id TEXT,
                message_id TEXT,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_creation_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                recorded_at REAL NOT NULL,
                day TEXT NOT NULL
            );
            CREATE INDEX intelligence_usage_recorded ON intelligence_usage (recorded_at);
            """),
        // Attachments are references (JSON), never copies of the attached text. The search tables
        // index titles and visible message text; their rowids are the indexed rows' rowids.
        Migration("0002_message_attachments_and_search") { db in
            try db.executeScript("""
                ALTER TABLE intelligence_messages ADD COLUMN attachments TEXT;
                CREATE VIRTUAL TABLE intelligence_conversation_search USING fts5(
                    title, tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE VIRTUAL TABLE intelligence_message_search USING fts5(
                    text, tokenize = 'unicode61 remove_diacritics 2'
                );
                """)
            try ConversationSearchIndex.rebuild(in: db)
        },
    ])
}
