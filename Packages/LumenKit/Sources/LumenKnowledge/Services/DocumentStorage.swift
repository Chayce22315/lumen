import Foundation

/// Where imported document bytes live. Keys are plain file names (`<sha256>.<extension>`).
public protocol DocumentStorage: Sendable {
    /// Stores `data` under `key`, replacing any previous content.
    func write(_ data: Data, key: String) async throws
    /// The bytes stored under `key`; throws `KnowledgeError.documentFileMissing` when absent.
    func read(key: String) async throws -> Data
    /// Removes the bytes under `key`. Removing a missing key succeeds.
    func remove(key: String) async throws
    func exists(key: String) async -> Bool
    /// A file URL for the stored bytes (for previews and sharing), when the storage is file-backed
    /// and the key is valid.
    func url(for key: String) -> URL?
}

/// Validation of storage keys: a key is a single, non-hidden path component.
public enum DocumentStorageKey {
    public static let maximumLength = 255

    public static func isValid(_ key: String) -> Bool {
        !key.isEmpty
            && key.utf8.count <= maximumLength
            && !key.hasPrefix(".")
            && !key.contains("/")
            && !key.contains("\\")
            && !key.contains("\0")
    }

    public static func validate(_ key: String) throws {
        guard isValid(key) else { throw KnowledgeError.invalidStorageKey(key) }
    }
}
