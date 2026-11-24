import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

@Suite("Conversation search")
struct ConversationSearchTests {
    @Test("titles match first, then messages; terms are prefixes, case and accents ignored")
    func ranking() async throws {
        let harness = try await EngineHarness.make()
        let service = harness.conversations
        let titled = try await service.create(title: "Résumé review")
        let other = try await service.create(title: "Weekend plans")
        try await store(["Can you polish my resume before Friday?", "Sure, send it over."], in: other.id, harness: harness)
        let unrelated = try await service.create(title: "Groceries")
        try await store(["Milk and eggs"], in: unrelated.id, harness: harness)
        try await store(["The résumé should fit one page."], in: titled.id, harness: harness)

        let hits = try await service.search("RESU")
        #expect(hits.map(\.conversation.id) == [titled.id, other.id])
        #expect(hits.first?.titleMatches == true)
        #expect(hits.first?.matchedText == "The résumé should fit one page.")
        #expect(hits.last?.titleMatches == false)
        #expect(hits.last?.matchedText == "Can you polish my resume before Friday?")

        // Every term must match.
        #expect(try await service.search("resume friday").map(\.conversation.id) == [other.id])
        #expect(try await service.search("resume tuesday").isEmpty)
        // Nothing searchable in the text.
        #expect(try await service.search("  ?!  ").isEmpty)
    }

    @Test("renames, deletions, archiving and tool output are reflected")
    func indexFollowsChanges() async throws {
        let harness = try await EngineHarness.make()
        let service = harness.conversations
        let conversation = try await service.create(title: "Old name")
        #expect(try await service.search("old").count == 1)
        _ = try await service.rename(conversation.id, to: "Budget")
        #expect(try await service.search("old").isEmpty)
        #expect(try await service.search("budg").map(\.conversation.id) == [conversation.id])

        _ = try await service.setArchived(true, for: conversation.id)
        #expect(try await service.search("budget").first?.conversation.isArchived == true)

        // Tool calls and results are not searchable; visible text is.
        let message = ChatMessage(
            conversationID: conversation.id, role: .assistant,
            blocks: [.text("Here is the summary."), .toolUse(id: "t1", name: "search_lumen", input: ["query": "zebra"])],
            createdAt: harness.environment.clock.now()
        )
        try await harness.environment.database.write { db in try MessageRepository.save(message, in: db) }
        #expect(try await service.search("summary").first?.matchedMessageID == message.id)
        #expect(try await service.search("zebra").isEmpty)

        try await service.delete(conversation.id)
        #expect(try await service.search("budget").isEmpty)
        #expect(try await service.search("summary").isEmpty)
        let leftovers = try await harness.environment.database.read { db in
            try db.scalar("SELECT count(*) FROM intelligence_message_search", as: Int.self)
        }
        #expect(leftovers == 0)
    }

    @Test("rows applied by sync are indexed like local ones")
    func syncedRows() async throws {
        let harness = try await EngineHarness.make()
        let conversation = Conversation(title: "From the laptop", createdAt: harness.environment.clock.now())
        let message = ChatMessage(conversationID: conversation.id, role: .user, blocks: [.text("Quarterly numbers")], createdAt: harness.environment.clock.now())
        try await harness.environment.database.write(origin: .remote) { db in
            try ConversationRepository.upsertRow(conversation, in: db)
            try MessageRepository.upsertRow(message, in: db)
        }
        #expect(try await harness.conversations.search("laptop").map(\.id) == [conversation.id])
        #expect(try await harness.conversations.search("quarterly").first?.matchedMessageID == message.id)

        try await harness.environment.database.write(origin: .remote) { db in
            try MessageRepository.deleteRow(message.id, in: db)
        }
        #expect(try await harness.conversations.search("quarterly").isEmpty)
    }

    @Test("the migration indexes conversations and messages that already exist")
    func migrationBackfill() async throws {
        let clock = ManualTimeSource()
        let database = try Database(location: .inMemory, timeSource: clock, logger: .disabled())
        let full = IntelligenceSchema.schema
        try await database.migrate([DatabaseSchema(namespace: full.namespace, migrations: Array(full.migrations.prefix(1)))])
        let conversationID = Conversation.ID()
        let blocks = String(decoding: try JSONEncoder().encode([ContentBlock.text("Pack the tent")]), as: UTF8.self)
        try await database.write { db in
            try db.execute(
                "INSERT INTO intelligence_conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
                [conversationID, "Camping trip", clock.now(), clock.now()]
            )
            try db.execute(
                "INSERT INTO intelligence_messages (id, conversation_id, role, blocks, status, created_at) VALUES (?, ?, 'user', ?, 'complete', ?)",
                [ChatMessage.ID(), conversationID, blocks, clock.now()]
            )
        }
        try await database.migrate([full])

        let service = ConversationService(database: database, events: EventBus(), timeSource: clock, logger: .disabled())
        #expect(try await service.search("camp").map(\.id) == [conversationID])
        #expect(try await service.search("tent").first?.matchedText == "Pack the tent")
        let messages = try await service.messages(in: conversationID)
        #expect(messages.first?.attachments == [])
    }

    private func store(_ texts: [String], in conversationID: Conversation.ID, harness: EngineHarness) async throws {
        for text in texts {
            harness.environment.clock.advance(by: 1)
            let message = ChatMessage(conversationID: conversationID, role: .user, blocks: [.text(text)], createdAt: harness.environment.clock.now())
            try await harness.environment.database.write { db in try MessageRepository.save(message, in: db) }
        }
    }
}
