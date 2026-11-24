import Foundation
import Synchronization

/// Process-local document storage for tests and previews.
public final class InMemoryDocumentStorage: DocumentStorage {
    private let files = Mutex<[String: Data]>([:])

    public init(_ initial: [String: Data] = [:]) {
        files.withLock { $0 = initial }
    }

    public func write(_ data: Data, key: String) async throws {
        try DocumentStorageKey.validate(key)
        files.withLock { $0[key] = data }
    }

    public func read(key: String) async throws -> Data {
        try DocumentStorageKey.validate(key)
        guard let data = files.withLock({ $0[key] }) else {
            throw KnowledgeError.documentFileMissing(storageKey: key)
        }
        return data
    }

    public func remove(key: String) async throws {
        try DocumentStorageKey.validate(key)
        _ = files.withLock { $0.removeValue(forKey: key) }
    }

    public func exists(key: String) async -> Bool {
        files.withLock { $0[key] != nil }
    }

    /// In-memory storage has no file URLs.
    public func url(for key: String) -> URL? { nil }

    /// Keys currently stored, sorted.
    public var keys: [String] {
        files.withLock { $0.keys.sorted() }
    }
}
