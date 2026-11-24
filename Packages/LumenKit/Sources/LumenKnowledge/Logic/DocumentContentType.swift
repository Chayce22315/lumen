import Foundation

/// Content types (uniform type identifiers) of imported documents, how they map to file
/// extensions, and which of them have extractable text.
public enum DocumentContentType {
    public static let plainText = "public.plain-text"
    public static let utf8PlainText = "public.utf8-plain-text"
    public static let markdown = "net.daringfireball.markdown"
    public static let json = "public.json"
    public static let commaSeparatedText = "public.comma-separated-values-text"
    public static let pdf = "com.adobe.pdf"
    public static let png = "public.png"
    public static let jpeg = "public.jpeg"
    public static let heic = "public.heic"
    /// Generic binary data, used when nothing more specific is known.
    public static let data = "public.data"

    /// Content types whose bytes are decoded as UTF-8 text on import. MIME equivalents are
    /// accepted too.
    public static let textExtractable: Set<String> = [
        plainText, utf8PlainText, "public.text", markdown, json, commaSeparatedText,
        "text/plain", "text/markdown", "text/x-markdown", "application/json", "text/csv",
    ]

    private static let extensionsByType: [String: String] = [
        plainText: "txt", utf8PlainText: "txt", "public.text": "txt", markdown: "md", json: "json",
        commaSeparatedText: "csv", pdf: "pdf", png: "png", jpeg: "jpg", heic: "heic",
        "text/plain": "txt", "text/markdown": "md", "text/x-markdown": "md", "application/json": "json",
        "text/csv": "csv", "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg",
    ]

    private static let typesByExtension: [String: String] = [
        "txt": plainText, "text": plainText, "md": markdown, "markdown": markdown, "json": json,
        "csv": commaSeparatedText, "pdf": pdf, "png": png, "jpg": jpeg, "jpeg": jpeg, "heic": heic,
    ]

    public static func isTextExtractable(_ contentType: String) -> Bool {
        textExtractable.contains(contentType.lowercased())
    }

    public static func preferredFileExtension(for contentType: String) -> String? {
        extensionsByType[contentType.lowercased()]
    }

    /// Best guess from a file name's extension; `data` when unknown.
    public static func inferred(fromFileName fileName: String) -> String {
        fileExtension(of: fileName).flatMap { typesByExtension[$0] } ?? data
    }

    /// Lowercased extension of `fileName` when it is a plausible one (1–10 letters or digits).
    public static func fileExtension(of fileName: String) -> String? {
        guard let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex else { return nil }
        let candidate = fileName[fileName.index(after: dot)...].lowercased()
        guard (1...10).contains(candidate.count),
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return candidate
    }

    /// `<sha256>.<extension>`, taking the extension from the file name, else from the content
    /// type; just `<sha256>` when neither provides one.
    public static func storageKey(sha256: String, fileName: String, contentType: String) -> String {
        if let ext = fileExtension(of: fileName) ?? preferredFileExtension(for: contentType) {
            return "\(sha256).\(ext)"
        }
        return sha256
    }

    /// The UTF-8 text of `data` for text-extractable types, without a byte-order mark, cut to
    /// `limit` characters. `nil` for other types and for bytes that are not valid UTF-8.
    public static func extractText(from data: Data, contentType: String, limit: Int) -> String? {
        guard isTextExtractable(contentType), limit > 0 else { return nil }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}
