import Foundation
import Testing
import LumenKnowledge

@Suite("DocumentStorage")
struct DocumentStorageTests {
    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-knowledge-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("file system storage writes, reads, reports and removes files")
    func fileSystemRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer {
            // Best-effort cleanup of the temporary test directory.
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = FileSystemDocumentStorage(directory: directory)
        let data = Data("contents".utf8)

        #expect(await !storage.exists(key: "abc.txt"))
        try await storage.write(data, key: "abc.txt")
        #expect(await storage.exists(key: "abc.txt"))
        #expect(try await storage.read(key: "abc.txt") == data)
        #expect(storage.url(for: "abc.txt") == directory.appendingPathComponent("abc.txt"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("abc.txt").path))

        try await storage.write(Data("replaced".utf8), key: "abc.txt")
        #expect(try await storage.read(key: "abc.txt") == Data("replaced".utf8))

        try await storage.remove(key: "abc.txt")
        try await storage.remove(key: "abc.txt")
        #expect(await !storage.exists(key: "abc.txt"))
        await #expect(throws: KnowledgeError.documentFileMissing(storageKey: "abc.txt")) {
            try await storage.read(key: "abc.txt")
        }
    }

    @Test("keys that are not plain file names are rejected by both storages", arguments: ["", "../escape", "a/b", ".hidden", "a\\b", String(repeating: "k", count: 256)])
    func invalidKeys(key: String) async throws {
        let directory = temporaryDirectory()
        let fileSystem = FileSystemDocumentStorage(directory: directory)
        let memory = InMemoryDocumentStorage()
        #expect(!DocumentStorageKey.isValid(key))
        await #expect(throws: KnowledgeError.invalidStorageKey(key)) { try await fileSystem.write(Data(), key: key) }
        await #expect(throws: KnowledgeError.invalidStorageKey(key)) { try await memory.write(Data(), key: key) }
        await #expect(throws: KnowledgeError.invalidStorageKey(key)) { try await fileSystem.read(key: key) }
        #expect(fileSystem.url(for: key) == nil)
        #expect(await !fileSystem.exists(key: key))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("in-memory storage behaves like the file system one")
    func inMemory() async throws {
        let storage = InMemoryDocumentStorage(["seed.bin": Data([1])])
        #expect(storage.keys == ["seed.bin"])
        try await storage.write(Data([2]), key: "other.bin")
        #expect(try await storage.read(key: "other.bin") == Data([2]))
        try await storage.remove(key: "seed.bin")
        try await storage.remove(key: "seed.bin")
        #expect(storage.keys == ["other.bin"])
        #expect(storage.url(for: "other.bin") == nil)
        await #expect(throws: KnowledgeError.self) { try await storage.read(key: "seed.bin") }
    }
}
