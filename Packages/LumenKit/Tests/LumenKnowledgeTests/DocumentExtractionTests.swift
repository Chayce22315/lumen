import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenTestSupport

/// Stands in for PDFKit: answers for one content type and records what it was asked.
final class FakeExtractor: DocumentTextExtractor {
    enum Behavior: Sendable {
        case text(String?)
        case fail
    }

    struct Failed: Error {}

    let contentType: String
    let behavior: Behavior
    private let calls = Mutex<[(contentType: String, limit: Int, bytes: Int)]>([])

    init(contentType: String = DocumentContentType.pdf, behavior: Behavior) {
        self.contentType = contentType
        self.behavior = behavior
    }

    var requests: [(contentType: String, limit: Int, bytes: Int)] { calls.withLock { $0 } }

    func canExtract(contentType: String) -> Bool {
        contentType == self.contentType
    }

    func extractText(from data: Data, contentType: String, limit: Int) async throws -> String? {
        calls.withLock { $0.append((contentType, limit, data.count)) }
        switch behavior {
        case .text(let text): return text
        case .fail: throw Failed()
        }
    }
}

@Suite("Document text extraction")
struct DocumentExtractionTests {
    private func service(_ environment: CoreTestEnvironment, extractors: [any DocumentTextExtractor], storage: any DocumentStorage = InMemoryDocumentStorage()) -> DocumentService {
        DocumentService(
            database: environment.database, storage: storage, extractors: extractors,
            events: environment.events, timeSource: environment.clock, logger: environment.logger("documents")
        )
    }

    @Test("a platform extractor provides the text of PDFs")
    func pdfText() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [KnowledgeSchema.schema])
        let extractor = FakeExtractor(behavior: .text("Quarterly report"))
        let documents = service(environment, extractors: [extractor])
        let pdf = try await documents.import(data: Data([0x25, 0x50, 0x44, 0x46]), fileName: "Report.pdf", contentType: DocumentContentType.pdf)
        #expect(pdf.extractedText == "Quarterly report")
        #expect(try await documents.document(pdf.id)?.extractedText == "Quarterly report")
        #expect(extractor.requests.map(\.contentType) == [DocumentContentType.pdf])
        #expect(extractor.requests.first?.limit == DocumentService.maximumExtractedCharacters)
        #expect(extractor.requests.first?.bytes == 4)
    }

    @Test("text formats are decoded by the engine; other types without an extractor have no text")
    func onlyWhenNeeded() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [KnowledgeSchema.schema])
        let extractor = FakeExtractor(behavior: .text("never used"))
        let documents = service(environment, extractors: [extractor])
        let text = try await documents.import(data: Data("plain words".utf8), fileName: "a.txt", contentType: DocumentContentType.plainText)
        #expect(text.extractedText == "plain words")
        let image = try await documents.import(data: Data([1, 2, 3]), fileName: "b.png", contentType: DocumentContentType.png)
        #expect(image.extractedText == nil)
        #expect(extractor.requests.isEmpty)
    }

    @Test("a failing extractor doesn't fail the import; the document simply has no text")
    func failureIsLogged() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [KnowledgeSchema.schema])
        let documents = service(environment, extractors: [FakeExtractor(behavior: .fail)])
        let pdf = try await documents.import(data: Data([9, 9]), fileName: "Broken.pdf", contentType: DocumentContentType.pdf)
        #expect(pdf.extractedText == nil)
        #expect(try await documents.document(pdf.id) != nil)
        let notice = environment.logs.entries(atLeast: .notice).first { $0.message == "Document text could not be extracted" }
        #expect(notice?.metadata["contentType"] == DocumentContentType.pdf)
    }

    @Test("the preview URL is offered only while the file is on this device")
    func availableFileURL() async throws {
        let environment = try await CoreTestEnvironment.make(schemas: [KnowledgeSchema.schema])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) } // best-effort cleanup of the scratch directory
        let documents = service(environment, extractors: [], storage: FileSystemDocumentStorage(directory: directory))
        let document = try await documents.import(data: Data("hello".utf8), fileName: "hello.txt", contentType: DocumentContentType.plainText)

        let url = try #require(try await documents.availableFileURL(for: document.id))
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        #expect(try await documents.availableFileURL(for: document.id) == nil)
        #expect(try await documents.fileURL(for: document.id) != nil) // the plain URL doesn't check

        let inMemory = service(environment, extractors: [])
        #expect(try await inMemory.availableFileURL(for: document.id) == nil)
    }
}
