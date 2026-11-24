import Foundation
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenSync

/// Document storage that fetches a file added on another device the first time it is read.
/// Document metadata synchronizes through the change log; the bytes follow on demand, verified
/// against the document's SHA-256 before they are kept.
struct SyncingDocumentStorage: DocumentStorage {
    let local: any DocumentStorage
    let blobs: BlobSynchronizer

    func write(_ data: Data, key: String) async throws {
        try await local.write(data, key: key)
    }

    func read(key: String) async throws -> Data {
        do {
            return try await local.read(key: key)
        } catch let error as KnowledgeError {
            guard case .documentFileMissing = error, blobs.isConfigured, let sha256 = Self.sha256(fromStorageKey: key) else {
                throw error
            }
            let data = try await blobs.download(sha256: sha256)
            try await local.write(data, key: key)
            return data
        }
    }

    func remove(key: String) async throws {
        try await local.remove(key: key)
    }

    func exists(key: String) async -> Bool {
        await local.exists(key: key)
    }

    func url(for key: String) -> URL? {
        local.url(for: key)
    }

    /// Storage keys are `<sha256>.<extension>` (or the bare hash).
    static func sha256(fromStorageKey key: String) -> String? {
        let hash = key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? key
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash.lowercased()
    }
}

/// Uploads the files of documents stored on this device after each successful sync run, so other
/// devices can download them.
public actor DocumentFileSync {
    private let documents: DocumentService
    private let local: any DocumentStorage
    private let blobs: BlobSynchronizer
    private let events: EventBus
    private let logger: Logger
    private var subscription: Task<Void, Never>?

    init(documents: DocumentService, local: any DocumentStorage, blobs: BlobSynchronizer, events: EventBus, logger: Logger) {
        self.documents = documents
        self.local = local
        self.blobs = blobs
        self.events = events
        self.logger = logger
    }

    /// Whether a sync service that carries files is configured.
    public nonisolated var isConfigured: Bool { blobs.isConfigured }

    func start() {
        guard blobs.isConfigured, subscription == nil else { return }
        let runs = events.events(matching: EventFilter(names: [SyncEngine.runCompletedEvent]))
        subscription = Task { [weak self] in
            for await event in runs where event.attributes["outcome"] == .string(SyncRun.Outcome.succeeded.rawValue) {
                await self?.uploadPending()
            }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Uploads files not uploaded before. Files that aren't on this device are skipped: the
    /// device that has them uploads them.
    @discardableResult
    public func uploadPending() async -> BlobUploadReport {
        guard blobs.isConfigured else { return BlobUploadReport() }
        let candidates: [BlobReference]
        do {
            var references: [BlobReference] = []
            for document in try await documents.allDocuments() where await local.exists(key: document.storageKey) {
                references.append(BlobReference(sha256: document.sha256, storageKey: document.storageKey))
            }
            candidates = references
        } catch {
            logger.error("Could not list documents to upload", error: error)
            var report = BlobUploadReport()
            report.stoppedEarly = true
            return report
        }
        let local = self.local
        return await blobs.uploadPending(candidates) { reference in
            try await local.read(key: reference.storageKey)
        }
    }
}
