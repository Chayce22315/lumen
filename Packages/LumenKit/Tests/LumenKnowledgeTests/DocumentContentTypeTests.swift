import Foundation
import Testing
import LumenKnowledge

@Suite("DocumentContentType")
struct DocumentContentTypeTests {
    let sha = String(repeating: "ab", count: 32)

    @Test("storage keys use the file's extension, else the content type's, else none")
    func storageKeys() {
        #expect(DocumentContentType.storageKey(sha256: sha, fileName: "Report.PDF", contentType: DocumentContentType.pdf) == "\(sha).pdf")
        #expect(DocumentContentType.storageKey(sha256: sha, fileName: "notes", contentType: DocumentContentType.markdown) == "\(sha).md")
        #expect(DocumentContentType.storageKey(sha256: sha, fileName: "blob", contentType: "com.example.unknown") == sha)
        #expect(DocumentContentType.storageKey(sha256: sha, fileName: "../../etc/passwd", contentType: DocumentContentType.data) == sha)
    }

    @Test("file extensions must be short and alphanumeric")
    func fileExtensions() {
        #expect(DocumentContentType.fileExtension(of: "photo.JPEG") == "jpeg")
        #expect(DocumentContentType.fileExtension(of: "archive.tar.gz") == "gz")
        #expect(DocumentContentType.fileExtension(of: ".hidden") == nil)
        #expect(DocumentContentType.fileExtension(of: "name.") == nil)
        #expect(DocumentContentType.fileExtension(of: "a.verylongextension") == nil)
        #expect(DocumentContentType.fileExtension(of: "a.p-f") == nil)
        #expect(DocumentContentType.inferred(fromFileName: "Read me.md") == DocumentContentType.markdown)
        #expect(DocumentContentType.inferred(fromFileName: "scan.pdf") == DocumentContentType.pdf)
        #expect(DocumentContentType.inferred(fromFileName: "mystery.xyz") == DocumentContentType.data)
    }

    @Test("text is extracted only from text formats")
    func extraction() {
        let text = Data("héllo, world".utf8)
        for type in [DocumentContentType.plainText, DocumentContentType.markdown, DocumentContentType.json, DocumentContentType.commaSeparatedText, "text/csv", "Public.Plain-Text"] {
            #expect(DocumentContentType.extractText(from: text, contentType: type, limit: 100) == "héllo, world", "\(type)")
        }
        #expect(DocumentContentType.extractText(from: text, contentType: DocumentContentType.pdf, limit: 100) == nil)
        #expect(DocumentContentType.extractText(from: text, contentType: DocumentContentType.png, limit: 100) == nil)
    }

    @Test("extraction strips a BOM, caps length and rejects invalid UTF-8")
    func extractionEdges() {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("# Title".utf8)
        #expect(DocumentContentType.extractText(from: bom, contentType: DocumentContentType.markdown, limit: 100) == "# Title")
        #expect(DocumentContentType.extractText(from: Data("abcdef".utf8), contentType: DocumentContentType.plainText, limit: 3) == "abc")
        #expect(DocumentContentType.extractText(from: Data([0xFF, 0xFE, 0x41]), contentType: DocumentContentType.plainText, limit: 100) == nil)
        #expect(DocumentContentType.extractText(from: Data(), contentType: DocumentContentType.plainText, limit: 100) == "")
    }
}
