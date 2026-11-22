import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenIntelligence
import LumenSearch
import LumenApplication
import LumenPresentation
import LumenTestSupport

@MainActor
@Suite("Assistant and document view models")
struct AssistantLibraryViewModelTests {
    @Test("conversation search highlights title and message matches and clears with the field")
    func conversationSearch() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let trip = try await services.intelligence.conversations.create(title: "Trip to Lisbon")
        let other = try await services.intelligence.conversations.create(title: "Weekly review")
        let message = ChatMessage(conversationID: other.id, role: .user, blocks: [.text("Remind me to book the Lisbon hotel before Friday please")], createdAt: clock.now())
        try await services.database.write { db in try MessageRepository.save(message, in: db) }

        let list = ConversationsViewModel(services: services, debounce: 0)
        await list.start()
        #expect(list.searchResults == nil)
        list.searchQuery = "lisb"
        #expect(await eventually { list.searchResults?.count == 2 })
        let rows = try #require(list.searchResults)
        #expect(rows.map(\.conversation.id) == [trip.id, other.id])
        #expect(rows.first?.titleHighlights == [HighlightRange(offset: 8, length: 4)])
        #expect(rows.first?.snippet == nil)
        let snippet = try #require(rows.last?.snippet)
        #expect(snippet.text.contains("Lisbon hotel"))
        #expect(!snippet.highlights.isEmpty)

        list.searchQuery = "  "
        #expect(list.searchResults == nil)
        await runtime.shutdown()
    }

    @Test("the model picker is hidden without a usable model and only accepts offered models")
    func modelPicker() async throws {
        let (services, runtime) = try await makeServices()
        let conversation = try await services.intelligence.conversations.create()
        let chat = ChatViewModel(conversationID: conversation.id, services: services)
        await chat.start()
        #expect(!chat.canChooseModel) // no provider keys in this environment
        #expect(chat.activeSelection == nil)
        #expect(chat.followsDefaultModel)

        await chat.chooseModel(ModelSelection(providerID: .anthropic, modelID: "made-up"))
        #expect(chat.conversation?.selection == nil)
        #expect(try await services.intelligence.conversations.conversation(conversation.id)?.selection == nil)

        let fallback = ModelSelection(providerID: .anthropic, modelID: "claude-opus-5-5")
        try await services.settings.set(fallback, for: AssistantSettings.defaultModel)
        await chat.loadModels()
        #expect(chat.activeSelection == fallback)
        #expect(chat.defaultModelName == "claude-opus-5-5") // not listed offline: the identifier is shown
        await runtime.shutdown()
    }

    @Test("attachments are de-duplicated, capped, and restored with the draft when sending fails")
    func attachmentsAndFailedSend() async throws {
        let (services, runtime) = try await makeServices()
        let conversation = try await services.intelligence.conversations.create()
        let note = try await services.knowledge.notes.create(title: "Plan", body: "Steps")
        let chat = ChatViewModel(conversationID: conversation.id, services: services)
        await chat.start()

        let candidate = AttachmentCandidate(reference: note.reference, title: "Plan", detail: "Note", kind: .note, updatedAt: note.updatedAt)
        chat.attach(candidate)
        chat.attach(candidate)
        #expect(chat.attachments.count == 1)
        for _ in 0..<20 {
            chat.attach(AttachmentCandidate(reference: EntityReference(kind: .note, id: UUID()), title: "x", detail: "Note", kind: .note, updatedAt: note.updatedAt))
        }
        #expect(chat.attachments.count == ChatViewModel.maximumAttachments)
        #expect(!chat.canAttachMore)
        for extra in chat.attachments.dropFirst() {
            chat.removeAttachment(extra.reference)
        }
        #expect(chat.attachments.map(\.reference) == [note.reference])

        // No model is configured, so the turn fails before anything is stored.
        chat.draft = "Summarise my plan"
        await chat.send()
        #expect(chat.failure != nil)
        #expect(chat.messages.isEmpty)
        #expect(chat.draft == "Summarise my plan")
        #expect(chat.attachments.map(\.reference) == [note.reference])
        await runtime.shutdown()
    }

    @Test("the attachment picker lists items with text, newest first, and filters by title and content")
    func attachmentPicker() async throws {
        let clock = ManualTimeSource()
        let (services, runtime) = try await makeServices(clock: clock)
        let knowledge = services.knowledge
        let older = try await knowledge.notes.create(title: "Garden", body: "Plant tulips in October")
        clock.advance(by: 60)
        _ = try await knowledge.notes.create(title: "Blank", body: "")
        let document = try await knowledge.documents.import(data: Data("Boiler service every spring".utf8), fileName: "House.txt", contentType: DocumentContentType.plainText)
        _ = try await knowledge.documents.import(data: Data([1, 2]), fileName: "photo.png", contentType: DocumentContentType.png)

        let picker = AttachmentPickerViewModel(services: services, debounce: 0)
        await picker.load()
        #expect(picker.state.value?.map(\.reference) == [document.reference, older.reference])
        #expect(picker.state.value?.first?.kind == .document)

        picker.query = "tulip" // body text, through the search index
        #expect(await eventually { picker.state.value?.map(\.reference) == [older.reference] })
        picker.query = "hous" // title
        #expect(await eventually { picker.state.value?.map(\.reference) == [document.reference] })
        picker.query = ""
        #expect(await eventually { picker.state.value?.count == 2 })
        await runtime.shutdown()
    }

    @Test("document details load, offer no preview without a file, and report a missing document")
    func documentDetail() async throws {
        let (services, runtime) = try await makeServices()
        let document = try await services.knowledge.documents.import(data: Data("hello".utf8), fileName: "hello.txt", contentType: DocumentContentType.plainText)
        let detail = DocumentDetailViewModel(documentID: document.id, services: services)
        await detail.start()
        #expect(detail.state.value?.title == "hello")
        #expect(!detail.canOpenFile) // tests store files in memory
        detail.preview()
        #expect(detail.previewURL == nil)

        let missing = DocumentDetailViewModel(documentID: DocumentItem.ID(), services: services)
        await missing.load()
        guard case .failed(let error) = missing.state else {
            Issue.record("expected a failure, got \(missing.state)")
            return
        }
        #expect(error.title == "Document not found")
        await runtime.shutdown()
    }
}
