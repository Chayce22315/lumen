import Foundation

/// Extracts searchable text from document formats the knowledge engine can't decode itself
/// (PDF, for example). The platform provides implementations through `PlatformServices`; the
/// engine decodes UTF-8 text formats on its own.
public protocol DocumentTextExtractor: Sendable {
    /// Whether this extractor reads documents of `contentType` (a uniform type identifier or
    /// MIME type, as stored on `DocumentItem`).
    func canExtract(contentType: String) -> Bool

    /// The document's text, cut to at most `limit` characters; `nil` when it has none (a scanned
    /// PDF without a text layer, a locked file). Throws when the data can't be read at all.
    func extractText(from data: Data, contentType: String, limit: Int) async throws -> String?
}
