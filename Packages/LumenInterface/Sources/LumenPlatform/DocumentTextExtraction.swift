import Foundation
import LumenApplication
import LumenKnowledge

extension LivePlatform {
    /// Readers for document formats the knowledge engine doesn't decode itself, so imported PDFs
    /// become searchable and can be attached to assistant messages.
    static var documentTextExtractors: [any DocumentTextExtractor] {
        #if canImport(PDFKit)
        return [PDFTextExtractor()]
        #else
        return []
        #endif
    }
}

extension PlatformServices {
    /// A copy that also reads the formats of `extractors`.
    func addingDocumentTextExtractors(_ extractors: [any DocumentTextExtractor]) -> PlatformServices {
        var copy = self
        copy.documentTextExtractors += extractors
        return copy
    }
}
