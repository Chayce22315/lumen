#if canImport(CloudKit)
import Foundation
@preconcurrency import CloudKit
import LumenSync

/// `CloudRecordDatabase` over the user's private CloudKit database, in Lumen's own zone.
///
/// Create it only for a build that has an iCloud container (see
/// `LivePlatform.cloudKitContainerIdentifier`): touching `CKContainer` without the iCloud
/// entitlement terminates the app. All merge, batching and retry logic lives in
/// `CloudSyncTransport`; this type only translates to and from CloudKit.
public struct CloudKitRecordDatabase: CloudRecordDatabase {
    public static let zoneName = "Lumen"
    public let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    private var container: CKContainer { CKContainer(identifier: containerIdentifier) }
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName) }

    // MARK: Zone

    public func zoneExists() async throws -> Bool {
        try await checkAccount()
        do {
            _ = try await database.recordZone(for: zoneID)
            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return false
        } catch {
            throw Self.translate(error)
        }
    }

    public func createZone() async throws {
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch {
            throw Self.translate(error)
        }
    }

    private func checkAccount() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw Self.translate(error)
        }
        switch status {
        case .available:
            return
        case .noAccount, .restricted:
            throw CloudDatabaseError.notAuthenticated
        case .couldNotDetermine, .temporarilyUnavailable:
            throw CloudDatabaseError.unavailable(retryAfter: nil)
        @unknown default:
            throw CloudDatabaseError.unavailable(retryAfter: nil)
        }
    }

    // MARK: Records

    public func records(_ ids: [CloudRecordID]) async throws -> [CloudRecordID: CloudRecord] {
        var found: [CloudRecordID: CloudRecord] = [:]
        for chunk in CloudBatching.chunks(ids, maximumCount: CloudLimits.maximumRecordsPerRequest) {
            let recordIDs = chunk.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) }
            let results: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                results = try await database.records(for: recordIDs)
            } catch {
                throw Self.translate(error)
            }
            for (recordID, result) in results {
                switch result {
                case .success(let record):
                    found[CloudRecordID(recordID.recordName)] = try Self.portable(record, includeAssets: true)
                case .failure(let error):
                    if (error as? CKError)?.code == .unknownItem { continue }
                    throw Self.translate(error)
                }
            }
        }
        return found
    }

    public func save(_ records: [CloudRecord]) async throws -> [CloudRecordID: CloudSaveOutcome] {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LumenCloudUpload-\(UUID().uuidString)", isDirectory: true)
        defer {
            // Best-effort cleanup of the staged asset files; the system purges the temporary
            // directory if this fails.
            try? FileManager.default.removeItem(at: staging)
        }
        var ckRecords: [CKRecord] = []
        for record in records {
            ckRecords.append(try makeRecord(record, staging: staging))
        }
        let database = self.database
        let response = try await translating {
            try await database.modifyRecords(saving: ckRecords, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        }
        var outcomes: [CloudRecordID: CloudSaveOutcome] = [:]
        for (recordID, result) in response.saveResults {
            let id = CloudRecordID(recordID.recordName)
            switch result {
            case .success(let saved):
                // The caller only needs to know it was saved; don't read the assets back.
                outcomes[id] = .saved(try Self.portable(saved, includeAssets: false))
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .serverRecordChanged, let server = ckError.serverRecord {
                    outcomes[id] = .conflict(server: try Self.portable(server, includeAssets: true))
                } else {
                    outcomes[id] = .failed(Self.translate(error))
                }
            }
        }
        return outcomes
    }

    private func makeRecord(_ record: CloudRecord, staging: URL) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id.name, zoneID: zoneID)
        // Reusing the server metadata makes the save conditional on the version that was read.
        // Unreadable metadata falls back to a new record, whose save then reports a conflict that
        // the transport merges.
        let ckRecord = record.systemFields.flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: record.type, recordID: recordID)
        for key in record.clearedFields {
            ckRecord[key] = nil
        }
        for (key, value) in record.fields {
            switch value {
            case .string(let text):
                ckRecord[key] = text as NSString
            case .int64(let number):
                ckRecord[key] = NSNumber(value: number)
            case .bytes(let data):
                ckRecord[key] = data as NSData
            case .asset(let data):
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let file = staging.appendingPathComponent(UUID().uuidString)
                try data.write(to: file, options: .atomic)
                ckRecord[key] = CKAsset(fileURL: file)
            }
        }
        return ckRecord
    }

    // MARK: Changes

    public func changes(since token: Data?, limit: Int) async throws -> CloudChangeBatch {
        let changeToken = try token.map(Self.changeToken(from:))
        let database = self.database
        let zoneID = self.zoneID
        let result = try await translating {
            try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken, desiredKeys: nil, resultsLimit: max(1, limit))
        }
        var changed: [CloudRecord] = []
        for (_, modification) in result.modificationResultsByID {
            switch modification {
            case .success(let change):
                changed.append(try Self.portable(change.record, includeAssets: true))
            case .failure(let error):
                if (error as? CKError)?.code == .unknownItem { continue }
                throw Self.translate(error)
            }
        }
        return CloudChangeBatch(
            changed: changed,
            deleted: result.deletions.map { CloudRecordID($0.recordID.recordName) },
            token: try Self.archive(result.changeToken),
            moreComing: result.moreComing
        )
    }

    // MARK: Translation

    /// Runs a CloudKit call, translating its errors.
    private func translating<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw Self.translate(error)
        }
    }

    static func portable(_ record: CKRecord, includeAssets: Bool) throws -> CloudRecord {
        var fields: [String: CloudValue] = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let text as String:
                fields[key] = .string(text)
            case let number as NSNumber:
                fields[key] = .int64(number.int64Value)
            case let data as Data:
                fields[key] = .bytes(data)
            case let asset as CKAsset:
                if includeAssets, let url = asset.fileURL {
                    fields[key] = .asset(try Data(contentsOf: url))
                } else {
                    fields[key] = .asset(Data())
                }
            default:
                continue
            }
        }
        return CloudRecord(id: CloudRecordID(record.recordID.recordName), type: record.recordType, fields: fields, systemFields: systemFields(of: record))
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func archive(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func changeToken(from data: Data) throws -> CKServerChangeToken {
        // An unreadable token is treated like an expired one: the transport reads from the start.
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            throw CloudDatabaseError.changeTokenExpired
        }
        return token
    }

    static func translate(_ error: any Error) -> CloudDatabaseError {
        if let error = error as? CloudDatabaseError { return error }
        guard let ckError = error as? CKError else { return .other(String(describing: type(of: error))) }
        switch ckError.code {
        case .changeTokenExpired:
            return .changeTokenExpired
        case .zoneNotFound, .userDeletedZone:
            return .zoneNotFound
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted:
            return .notAuthenticated
        case .quotaExceeded:
            return .quotaExceeded
        case .networkUnavailable, .networkFailure:
            return .network
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .unavailable(retryAfter: ckError.retryAfterSeconds)
        case .limitExceeded:
            return .limitExceeded
        case .partialFailure:
            if let first = ckError.partialErrorsByItemID?.values.first {
                return translate(first)
            }
            return .other("CloudKit partial failure")
        default:
            return .other("CloudKit error \(ckError.code.rawValue)")
        }
    }
}
#endif
