import Foundation
import LumenFoundation
import LumenPersistence

/// The full-text index over conversation titles and message text.
///
/// Two FTS5 tables (diacritic-folding `unicode61`) whose rowids are those of the conversation and
/// message rows they index. The repositories' `upsertRow`/`deleteRow` keep them in step, so local
/// writes and changes applied by sync are both searchable. Only visible text is indexed: tool
/// calls, tool results and reasoning are not.
enum ConversationSearchIndex {
    static func indexConversation(id: Conversation.ID, title: String, in db: DatabaseConnection) throws {
        guard let rowid = try db.scalar("SELECT rowid FROM intelligence_conversations WHERE id = ?", [id], as: Int64.self) else { return }
        try db.execute("DELETE FROM intelligence_conversation_search WHERE rowid = ?", [rowid])
        guard let title = title.nonBlank else { return }
        try db.execute("INSERT INTO intelligence_conversation_search (rowid, title) VALUES (?, ?)", [rowid, title])
    }

    /// Call before the conversation row is deleted.
    static func removeConversation(id: Conversation.ID, in db: DatabaseConnection) throws {
        try db.execute(
            "DELETE FROM intelligence_conversation_search WHERE rowid IN (SELECT rowid FROM intelligence_conversations WHERE id = ?)",
            [id]
        )
    }

    static func indexMessage(id: ChatMessage.ID, text: String, in db: DatabaseConnection) throws {
        guard let rowid = try db.scalar("SELECT rowid FROM intelligence_messages WHERE id = ?", [id], as: Int64.self) else { return }
        try db.execute("DELETE FROM intelligence_message_search WHERE rowid = ?", [rowid])
        guard let text = text.nonBlank else { return }
        try db.execute("INSERT INTO intelligence_message_search (rowid, text) VALUES (?, ?)", [rowid, text])
    }

    /// Call before the message row is deleted.
    static func removeMessage(id: ChatMessage.ID, in db: DatabaseConnection) throws {
        try db.execute(
            "DELETE FROM intelligence_message_search WHERE rowid IN (SELECT rowid FROM intelligence_messages WHERE id = ?)",
            [id]
        )
    }

    /// Indexes every existing conversation and message (run once, by the migration that creates
    /// the index). Reads raw columns rather than the model mappings, so later schema changes
    /// can't break this step on a fresh database.
    static func rebuild(in db: DatabaseConnection) throws {
        for row in try db.query("SELECT id, title FROM intelligence_conversations") {
            try indexConversation(id: try row.get("id"), title: try row.get("title"), in: db)
        }
        for row in try db.query("SELECT id, blocks FROM intelligence_messages") {
            let blocks: [ContentBlock] = try row.json("blocks")
            try indexMessage(id: try row.get("id"), text: blocks.compactMap(\.textValue).joined(), in: db)
        }
    }

    /// A safe `MATCH` expression: every token reduced to letters and digits, quoted, given a
    /// prefix wildcard and AND-ed. `nil` when the text has nothing searchable.
    static func matchExpression(for text: String, maximumTokens: Int = 12) -> String? {
        let tokens = text.matchingTokens.prefix(maximumTokens)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
