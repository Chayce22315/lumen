import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// A file to keep in the cloud: its content hash and where this device stores it.
public struct BlobReference: Hashable, Sendable {
    public let sha256: String
    public let storageKey: String

    public init(sha256: String, storageKey: String) {
        self.sha256 = sha256.lowercased()
        self.storageKey = storageKey
    }
}

public enum BlobSyncError: Error, Hashable, Sendable {
    /// No sync service carries files in this build.
    case notConfigured
    /// No device has uploaded the file yet.
    case notFound
    /// The downloaded bytes don't match the expected hash.
    case corrupted
}

extension BlobSyncError: PresentableError {
    public var presentation: ErrorPresentation {
        switch self {
        case .notConfigured:
            return ErrorPresentation(title: "File not on this device", message: "This document was added on another device and sync isn't set up here.")
        case .notFound:
            return ErrorPresentation(title: "File not uploaded yet", message: "The device that added this document hasn't finished uploading it. Try again later.", isRetryable: true)
        case .corrupted:
            return ErrorPresentation(title: "File damaged", message: "The downloaded file doesn't match the original, so Lumen didn't keep it.", isRetryable: true)
        }
    }
}

public struct BlobUploadReport: Hashable, Sendable {
    public var uploaded = 0
    public var alreadyInCloud = 0
    public var failed = 0
    /// Uploading stopped early (offline, signed out or cancelled); the rest is tried next time.
    public var stoppedEarly = false

    public init() {}
}

/// Uploads document files and downloads them on demand. Uploads are remembered per hash, so each
/// distinct file is uploaded once however many documents share it; downloads are verified.
public actor BlobSynchronizer {
    private let database: Database
    private let transport: (any BlobTransport)?
    private let digest: @Sendable (Data) -> String
    private let timeSource: any TimeSource
    private let logger: Logger

    /// - Parameter digest: the lowercase hexadecimal SHA-256 of some bytes.
    public init(database: Database, transport: (any BlobTransport)?, digest: @escaping @Sendable (Data) -> String, timeSource: any TimeSource, logger: Logger) {
        self.database = database
        self.transport = transport
        self.digest = digest
        self.timeSource = timeSource
        self.logger = logger
    }

    public nonisolated var isConfigured: Bool { transport != nil }

    /// Uploads the files among `candidates` not uploaded before. `read` returns a file's bytes.
    public func uploadPending(_ candidates: [BlobReference], read: @Sendable (BlobReference) async throws -> Data) async -> BlobUploadReport {
        var report = BlobUploadReport()
        guard let transport else { return report }
        let unique = Dictionary(candidates.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        let uploaded: Set<String>
        do {
            uploaded = try await database.read { db in
                Set(try db.query("SELECT sha256 FROM sync_blobs").map { row -> String in try row.get("sha256") })
            }
        } catch {
            logger.error("Could not read file upload state", error: error)
            report.stoppedEarly = true
            return report
        }
        for sha256 in unique.keys.sorted() where !uploaded.contains(sha256) {
            guard let candidate = unique[sha256] else { continue }
            if Task.isCancelled {
                report.stoppedEarly = true
                break
            }
            do {
                if try await transport.containsBlob(sha256: sha256) {
                    report.alreadyInCloud += 1
                } else {
                    let data = try await read(candidate)
                    guard digest(data) == sha256 else {
                        // The local copy changed or is damaged; uploading it would spread the damage.
                        logger.warning("A local document file doesn't match its hash; not uploading it")
                        report.failed += 1
                        continue
                    }
                    try await transport.uploadBlob(data, sha256: sha256)
                    report.uploaded += 1
                }
                try await markUploaded(sha256)
            } catch let error as SyncTransportError where error == .offline || error == .unauthorized {
                logger.notice("File uploads paused", metadata: ["reason": String(describing: error)])
                report.stoppedEarly = true
                break
            } catch {
                logger.error("A document file could not be uploaded", error: error)
                report.failed += 1
            }
        }
        if report.uploaded + report.failed > 0 {
            logger.info("Document files synchronized", metadata: ["uploaded": String(report.uploaded), "failed": String(report.failed)])
        }
        return report
    }

    /// Downloads a file by hash and verifies it.
    public func download(sha256: String) async throws -> Data {
        guard let transport else { throw BlobSyncError.notConfigured }
        let hash = sha256.lowercased()
        guard let data = try await transport.downloadBlob(sha256: hash) else { throw BlobSyncError.notFound }
        guard digest(data) == hash else { throw BlobSyncError.corrupted }
        try await markUploaded(hash)
        return data
    }

    private func markUploaded(_ sha256: String) async throws {
        let now = timeSource.now()
        try await database.write { db in
            try db.execute(
                "INSERT INTO sync_blobs (sha256, uploaded_at) VALUES (?, ?) ON CONFLICT(sha256) DO NOTHING",
                [sha256, now]
            )
        }
    }
}
