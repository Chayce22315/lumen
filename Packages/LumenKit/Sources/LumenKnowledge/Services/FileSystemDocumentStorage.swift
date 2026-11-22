import Foundation

/// Stores each document as a file in `directory` (created on first write). Writes are atomic.
public struct FileSystemDocumentStorage: DocumentStorage {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ data: Data, key: String) async throws {
        let fileURL = try location(of: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func read(key: String) async throws -> Data {
        let fileURL = try location(of: key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw KnowledgeError.documentFileMissing(storageKey: key)
        }
        return try Data(contentsOf: fileURL)
    }

    public func remove(key: String) async throws {
        let fileURL = try location(of: key)
        // Already absent: removal is idempotent.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public func exists(key: String) async -> Bool {
        guard DocumentStorageKey.isValid(key) else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(key).path)
    }

    public func url(for key: String) -> URL? {
        guard DocumentStorageKey.isValid(key) else { return nil }
        return directory.appendingPathComponent(key)
    }

    private func location(of key: String) throws -> URL {
        try DocumentStorageKey.validate(key)
        return directory.appendingPathComponent(key)
    }
}
