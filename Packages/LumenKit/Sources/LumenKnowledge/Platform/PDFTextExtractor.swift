#if canImport(PDFKit)
import Foundation
@preconcurrency import PDFKit

/// Text of PDF documents through PDFKit, page by page, stopping once `limit` characters are
/// collected. Locked (password-protected) PDFs and PDFs without a text layer yield `nil`.
public struct PDFTextExtractor: DocumentTextExtractor {
    public init() {}

    public func canExtract(contentType: String) -> Bool {
        let type = contentType.lowercased()
        return type == DocumentContentType.pdf || type == "application/pdf"
    }

    public func extractText(from data: Data, contentType: String, limit: Int) async throws -> String? {
        guard limit > 0 else { return nil }
        guard let document = PDFDocument(data: data) else {
            throw KnowledgeError.unreadableDocument
        }
        guard !document.isLocked else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let pageText = page.string, !pageText.isEmpty else { continue }
            if !text.isEmpty {
                text += "\n\n"
            }
            text += pageText
            if text.count >= limit { break }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }
}
#endif
