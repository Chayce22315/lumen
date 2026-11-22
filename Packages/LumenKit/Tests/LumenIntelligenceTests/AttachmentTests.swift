import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

/// Library items keyed by reference; edits and deletions are visible to the next read.
final class FakeAttachmentResolver: AttachmentResolver {
    private let items = Mutex<[EntityReference: AttachmentContent]>([:])
    private let reads = Mutex<[EntityReference]>([])
    private let failing = Mutex<Set<EntityReference>>([])

    struct ReadFailed: Error {}

    func set(_ reference: EntityReference, title: String, text: String, kind: String = "note") {
        items.withLock { $0[reference] = AttachmentContent(title: title, kind: kind, text: text) }
    }

    func remove(_ reference: EntityReference) {
        _ = items.withLock { $0.removeValue(forKey: reference) }
    }

    func fail(_ reference: EntityReference) {
        _ = failing.withLock { $0.insert(reference) }
    }

    var readReferences: [EntityReference] { reads.withLock { $0 } }

    func content(of reference: EntityReference) async throws -> AttachmentContent? {
        reads.withLock { $0.append(reference) }
        if failing.withLock({ $0.contains(reference) }) { throw ReadFailed() }
        return items.withLock { $0[reference] }
    }
}

@Suite("Attachment budget and prompt")
struct AttachmentLogicTests {
    @Test("shares are equal, and what short items leave goes to longer ones")
    func allocation() {
        #expect(AttachmentBudget.allocate(lengths: [100, 100], limit: 50) == [25, 25])
        #expect(AttachmentBudget.allocate(lengths: [10, 100, 1_000], limit: 300) == [10, 100, 190])
        #expect(AttachmentBudget.allocate(lengths: [5, 7], limit: 1_000) == [5, 7])
        #expect(AttachmentBudget.allocate(lengths: [40, 3], limit: 10) == [7, 3])
        #expect(AttachmentBudget.allocate(lengths: [10, 10], limit: 0) == [0, 0])
        #expect(AttachmentBudget.allocate(lengths: [], limit: 100) == [])
    }

    @Test("the limit is the ceiling or half the history budget, whichever is smaller")
    func characterLimit() {
        #expect(AttachmentBudget.characterLimit(historyBudgetTokens: 1_000_000, ceiling: 60_000) == 60_000)
        #expect(AttachmentBudget.characterLimit(historyBudgetTokens: 1_000, ceiling: 60_000) == 2_000)
        #expect(AttachmentBudget.characterLimit(historyBudgetTokens: 0, ceiling: 60_000) == 0)
    }

    @Test("blocks name the item, say when it was cut, and survive quotes and deletions")
    func prompt() {
        let reference = EntityReference(kind: "note", id: UUID())
        let whole = MessageAttachment(reference: reference, title: "Plan", includedCharacters: 5, totalCharacters: 5)
        #expect(AttachmentPrompt.block(for: whole, content: AttachmentContent(title: "Plan", kind: "note", text: "Hello"))
            == "<attachment kind=\"note\" title=\"Plan\">\nHello\n</attachment>")

        let cut = MessageAttachment(reference: reference, title: "Plan", includedCharacters: 3, totalCharacters: 5)
        #expect(AttachmentPrompt.block(for: cut, content: AttachmentContent(title: "The \"big\"\nplan", kind: "note", text: "Hello"))
            == "<attachment kind=\"note\" title=\"The 'big' plan\" truncated=\"first 3 of 5 characters\">\nHel\n</attachment>")

        #expect(AttachmentPrompt.block(for: whole, content: nil)
            == "<attachment title=\"Plan\" unavailable=\"true\">This item was deleted or no longer has text.</attachment>")
    }
}

@Suite("Assistant attachments")
struct AttachmentEngineTests {
    let note = EntityReference(kind: "note", id: UUID())
    let document = EntityReference(kind: "document", id: UUID())

    @Test("attachments go to the model ahead of the text; the message stores references only")
    func sentAndStored() async throws {
        let resolver = FakeAttachmentResolver()
        resolver.set(note, title: "Trip notes", text: "Flights on Friday.")
        resolver.set(document, title: "Itinerary.pdf", text: "Hotel: Seaview.", kind: "document")
        let harness = try await EngineHarness.make(attachmentResolver: resolver)
        let conversation = try await harness.conversations.create()

        var updates: [AssistantUpdate] = []
        for try await update in await harness.engine.send(text: "Summarise these", attachments: [note, document, note], in: conversation.id) {
            updates.append(update)
        }
        #expect(updates.failure == nil)

        let request = try #require(harness.provider.requests.first)
        #expect(request.messages.first == WireMessage(role: .user, blocks: [
            .text("<attachment kind=\"note\" title=\"Trip notes\">\nFlights on Friday.\n</attachment>"),
            .text("<attachment kind=\"document\" title=\"Itinerary.pdf\">\nHotel: Seaview.\n</attachment>"),
            .text("Summarise these"),
        ]))

        let stored = try #require(try await harness.messages(conversation.id).first)
        #expect(stored.blocks == [.text("Summarise these")])
        #expect(stored.attachments == [
            MessageAttachment(reference: note, title: "Trip notes", includedCharacters: 18, totalCharacters: 18),
            MessageAttachment(reference: document, title: "Itinerary.pdf", includedCharacters: 15, totalCharacters: 15),
        ])
        // The change-log snapshot (what sync sends) round-trips the attachments.
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(stored))
        #expect(decoded.attachments == stored.attachments)
    }

    @Test("later turns read the item again: edits show up, deletions are reported, nothing is copied")
    func replayReadsCurrentContent() async throws {
        let resolver = FakeAttachmentResolver()
        resolver.set(note, title: "Draft", text: "Version one of the essay.")
        let harness = try await EngineHarness.make(attachmentResolver: resolver)
        let conversation = try await harness.conversations.create()
        _ = await harness.send("Proofread this", in: conversation.id) // no attachment: plain turn
        var updates: [AssistantUpdate] = []
        for try await update in await harness.engine.send(text: "And this one", attachments: [note], in: conversation.id) {
            updates.append(update)
        }
        #expect(updates.failure == nil)

        resolver.set(note, title: "Draft", text: "Version two, which is much longer than before.")
        _ = await harness.send("Thanks", in: conversation.id)
        let replayed = try #require(harness.provider.requests.last?.messages.first { message in
            message.blocks.contains(.text("And this one"))
        })
        // Cut to the 25 characters recorded when it was sent.
        #expect(replayed.blocks.first == .text("<attachment kind=\"note\" title=\"Draft\" truncated=\"first 25 of 46 characters\">\nVersion two, which is muc\n</attachment>"))

        resolver.remove(note)
        _ = await harness.send("One more", in: conversation.id)
        let afterDeletion = try #require(harness.provider.requests.last?.messages.first { $0.blocks.contains(.text("And this one")) })
        #expect(afterDeletion.blocks.first == .text("<attachment title=\"Draft\" unavailable=\"true\">This item was deleted or no longer has text.</attachment>"))

        resolver.fail(note)
        let stillAnswers = await harness.send("Last one", in: conversation.id)
        #expect(stillAnswers.failure == nil)
        #expect(harness.environment.logs.entries(atLeast: .warning).contains { $0.message == "Attachment could not be read" })
    }

    @Test("a long attachment is cut to the budget and the message records it")
    func truncatedToBudget() async throws {
        let resolver = FakeAttachmentResolver()
        resolver.set(note, title: "Long", text: String(repeating: "a", count: 40))
        resolver.set(document, title: "Short", text: "bcd", kind: "document")
        let harness = try await EngineHarness.make(
            configuration: AssistantEngine.Configuration(maxAttachmentCharacters: 10),
            attachmentResolver: resolver
        )
        let conversation = try await harness.conversations.create()
        for try await _ in await harness.engine.send(text: "Look", attachments: [note, document], in: conversation.id) {}

        let stored = try #require(try await harness.messages(conversation.id).first)
        #expect(stored.attachments.map(\.includedCharacters) == [7, 3])
        #expect(stored.attachments.map(\.isTruncated) == [true, false])
        let request = try #require(harness.provider.requests.first)
        #expect(request.messages.first?.blocks.first == .text("<attachment kind=\"note\" title=\"Long\" truncated=\"first 7 of 40 characters\">\naaaaaaa\n</attachment>"))
    }

    @Test("unavailable or too many attachments fail before anything is stored")
    func rejectedBeforePersisting() async throws {
        let resolver = FakeAttachmentResolver()
        resolver.set(note, title: "Empty", text: "   ")
        let harness = try await EngineHarness.make(
            configuration: AssistantEngine.Configuration(maxAttachmentsPerMessage: 1),
            attachmentResolver: resolver
        )
        let conversation = try await harness.conversations.create()

        let missing = await sendCollecting(harness, attachments: [document], in: conversation.id)
        #expect(missing.failure == AssistantError.attachmentUnavailable.presentation)
        let blank = await sendCollecting(harness, attachments: [note], in: conversation.id)
        #expect(blank.failure == AssistantError.attachmentUnavailable.presentation)
        let many = await sendCollecting(harness, attachments: [note, document], in: conversation.id)
        #expect(many.failure == AssistantError.tooManyAttachments(1).presentation)

        #expect(try await harness.messages(conversation.id).isEmpty)
        #expect(harness.provider.requests.isEmpty)
        #expect(try await harness.conversations.conversation(conversation.id)?.title == "")
    }

    @Test("without a resolver attachments are refused")
    func noResolver() async throws {
        let harness = try await EngineHarness.make()
        let conversation = try await harness.conversations.create()
        let updates = await sendCollecting(harness, attachments: [note], in: conversation.id)
        #expect(updates.failure == AssistantError.attachmentUnavailable.presentation)
        #expect(try await harness.messages(conversation.id).isEmpty)
    }

    private func sendCollecting(_ harness: EngineHarness, attachments: [EntityReference], in id: Conversation.ID) async -> [AssistantUpdate] {
        var updates: [AssistantUpdate] = []
        do {
            for try await update in await harness.engine.send(text: "Hi", attachments: attachments, in: id) {
                updates.append(update)
            }
        } catch {
            Issue.record("The update stream threw: \(error)")
        }
        return updates
    }
}

@Suite("Model choices")
struct ModelChoiceTests {
    @Test("only providers that can answer are offered; failing lists are reported")
    func configuredOnly() async throws {
        let openAI = FakeProvider(id: .openAI, models: [ModelDescriptor(id: "gpt-x", displayName: "GPT X", providerID: .openAI)])
        let local = FakeProvider(id: "local", requiresAPIKey: false, models: [ModelDescriptor(id: "llama", displayName: "Llama", providerID: "local")])
        let empty = FakeProvider(id: "empty", requiresAPIKey: false, models: [])
        let harness = try await EngineHarness.make(extraProviders: [openAI, local, empty]) // only the Anthropic key is stored

        let choices = await harness.engine.modelChoices()
        #expect(choices.providers.map(\.id) == [.anthropic, "local"])
        #expect(choices.providers.first?.displayName == "Anthropic")
        #expect(choices.contains(EngineHarness.selection))
        #expect(!choices.contains(ModelSelection(providerID: .openAI, modelID: "gpt-x")))
        #expect(choices.descriptor(for: ModelSelection(providerID: "local", modelID: "llama"))?.displayName == "Llama")
        #expect(choices.unavailable.isEmpty)
        #expect(!choices.isEmpty)

        try harness.secrets.setSecret(ProviderFixtures.openAIKey, for: ProviderID.openAI.apiKeySecret)
        #expect(await harness.engine.modelChoices().providers.map(\.id) == [.anthropic, .openAI, "local"])
    }

    @Test("a configured provider whose list fails is reported, not offered")
    func failingList() async throws {
        let failing = FailingModelsProvider()
        let harness = try await EngineHarness.make(keys: [:], extraProviders: [failing])
        let choices = await harness.engine.modelChoices()
        #expect(choices.isEmpty)
        #expect(choices.unavailable[failing.id] != nil)
    }

    @Test("the conversation's override answers, and clearing it returns to the default")
    func overrideIsUsed() async throws {
        let local = FakeProvider(id: "local", requiresAPIKey: false, models: [ModelDescriptor(id: "llama", displayName: "Llama", providerID: "local")])
        let harness = try await EngineHarness.make(extraProviders: [local])
        let conversation = try await harness.conversations.create()
        let override = ModelSelection(providerID: "local", modelID: "llama")
        let changed = try await harness.conversations.setSelection(override, for: conversation.id)
        #expect(changed.selection == override)
        _ = await harness.send("Hello", in: conversation.id)
        #expect(local.requests.map(\.model) == ["llama"])
        #expect(harness.provider.requests.isEmpty)

        _ = try await harness.conversations.setSelection(nil, for: conversation.id)
        _ = await harness.send("Again", in: conversation.id)
        #expect(harness.provider.requests.map(\.model) == ["claude-opus-5-5"])

        let events = harness.events.events.filter { $0.name == IntelligenceEvents.conversationModelChanged }
        #expect(events.count == 2)
        #expect(events.first?.attributes["provider"] == .string("local"))
        #expect(events.last?.attributes["followsDefault"] == .bool(true))
    }
}

/// A key-less provider whose model list always fails.
final class FailingModelsProvider: ModelProvider {
    let id: ProviderID = "broken"
    let displayName = "Broken"
    let requiresAPIKey = false

    func availableModels() async throws -> [ModelDescriptor] {
        throw ProviderError.network("offline")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.network("offline")) }
    }
}
