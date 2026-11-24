import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenIntelligence
import LumenSearch
import LumenApplication
import LumenTestSupport

/// Pretends to read PDFs.
struct StubPDFExtractor: DocumentTextExtractor {
    func canExtract(contentType: String) -> Bool { contentType == DocumentContentType.pdf }
    func extractText(from data: Data, contentType: String, limit: Int) async throws -> String? { "Invoice for the harbour cottage" }
}

@Suite("Knowledge for the assistant")
struct KnowledgeAttachmentTests {
    @Test("notes and documents with text resolve; empty, image and deleted items don't")
    func resolver() async throws {
        let app = try await RunningApp.start()
        defer { try? FileManager.default.removeItem(at: app.directory) } // best-effort cleanup of the scratch directory
        let knowledge = app.services.knowledge
        let resolver = KnowledgeAttachmentResolver(notes: knowledge.notes, documents: knowledge.documents)

        let note = try await knowledge.notes.create(title: "  Packing   list ", body: "Tent, stove")
        #expect(try await resolver.content(of: note.reference) == AttachmentContent(title: "Packing list", kind: "note", text: "Tent, stove"))
        #expect(KnowledgeAttachmentResolver.isAttachable(note))

        let empty = try await knowledge.notes.create(title: "Empty", body: "  ")
        #expect(try await resolver.content(of: empty.reference) == nil)
        #expect(!KnowledgeAttachmentResolver.isAttachable(empty))

        let text = try await knowledge.documents.import(data: Data("Gate code 1234".utf8), fileName: "codes.txt", contentType: DocumentContentType.plainText)
        #expect(try await resolver.content(of: text.reference) == AttachmentContent(title: "codes", kind: "document", text: "Gate code 1234"))
        let image = try await knowledge.documents.import(data: Data([1, 2, 3]), fileName: "photo.png", contentType: DocumentContentType.png)
        #expect(try await resolver.content(of: image.reference) == nil)
        #expect(!KnowledgeAttachmentResolver.isAttachable(image))

        try await knowledge.notes.delete(note.id)
        #expect(try await resolver.content(of: note.reference) == nil)
        #expect(try await resolver.content(of: EntityReference(kind: .task, id: UUID())) == nil)
    }

    @Test("platform extractors make imported PDFs searchable")
    func pdfExtractorWiring() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // best-effort cleanup of the scratch directory
        var platform = PlatformServices.ephemeral()
        platform.documentTextExtractors = [StubPDFExtractor()]
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: ManualTimeSource(),
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        await runtime.start()
        let pdf = try await services.knowledge.documents.import(data: Data([0x25, 0x50]), fileName: "Invoice.pdf", contentType: DocumentContentType.pdf)
        #expect(pdf.extractedText == "Invoice for the harbour cottage")
        #expect(try await eventually {
            try await services.search.service.search(SearchQuery(text: "harbour")).contains { $0.reference == pdf.reference }
        })
        await runtime.shutdown()
    }
}
