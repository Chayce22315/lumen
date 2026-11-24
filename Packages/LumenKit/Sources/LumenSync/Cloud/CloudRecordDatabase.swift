import Foundation

/// The name of a record in the cloud database (CloudKit's `recordName`).
public struct CloudRecordID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var description: String { name }

    public static func < (lhs: CloudRecordID, rhs: CloudRecordID) -> Bool { lhs.name < rhs.name }
}

/// A field value. Mirrors the CloudKit value types Lumen uses.
public enum CloudValue: Hashable, Sendable {
    case string(String)
    case int64(Int64)
    case bytes(Data)
    /// Bytes stored as a file attachment, for payloads too large for a record field.
    case asset(Data)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var int64Value: Int64? {
        if case .int64(let value) = self { return value }
        return nil
    }

    /// The bytes of `.bytes` and `.asset` values.
    public var dataValue: Data? {
        switch self {
        case .bytes(let data), .asset(let data): return data
        case .string, .int64: return nil
        }
    }

    /// Approximate size in the record, for batching. Assets don't count towards a record's size.
    var inlineByteCount: Int {
        switch self {
        case .string(let text): return text.utf8.count
        case .int64: return 8
        case .bytes(let data): return data.count
        case .asset: return 0
        }
    }
}

/// A record in Lumen's zone: portable, so the transport logic is independent of CloudKit.
public struct CloudRecord: Hashable, Sendable {
    public var id: CloudRecordID
    public var type: String
    public var fields: [String: CloudValue]
    /// Fields to remove from the server copy when saving (a save only writes the fields it sets).
    public var clearedFields: Set<String>
    /// Opaque server metadata (CloudKit's encoded system fields, including the change tag);
    /// `nil` for a record that was never saved. Saving a record whose metadata is stale fails with
    /// a conflict instead of overwriting a newer server version.
    public var systemFields: Data?

    public init(id: CloudRecordID, type: String, fields: [String: CloudValue] = [:], clearedFields: Set<String> = [], systemFields: Data? = nil) {
        self.id = id
        self.type = type
        self.fields = fields
        self.clearedFields = clearedFields
        self.systemFields = systemFields
    }

    var inlineByteCount: Int {
        fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.inlineByteCount }
    }
}

/// What happened to one record of a save.
public enum CloudSaveOutcome: Hashable, Sendable {
    case saved(CloudRecord)
    /// The server has a newer version; it is returned so the caller can merge and retry.
    case conflict(server: CloudRecord)
    case failed(CloudDatabaseError)
}

/// One page of changes in the zone, oldest first.
public struct CloudChangeBatch: Hashable, Sendable {
    public var changed: [CloudRecord]
    public var deleted: [CloudRecordID]
    /// Opaque position after this page (CloudKit's archived server change token).
    public var token: Data
    public var moreComing: Bool

    public init(changed: [CloudRecord], deleted: [CloudRecordID], token: Data, moreComing: Bool) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

public enum CloudDatabaseError: Error, Hashable, Sendable {
    /// The change token is too old; changes must be fetched from the beginning.
    case changeTokenExpired
    /// Lumen's zone doesn't exist (never created, or deleted with the user's iCloud data).
    case zoneNotFound
    /// No iCloud account, or iCloud is restricted for this app.
    case notAuthenticated
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// No connectivity.
    case network
    /// The service asked to slow down or is temporarily unavailable.
    case unavailable(retryAfter: TimeInterval?)
    /// The request was too large (too many records or bytes); split it and retry.
    case limitExceeded
    case other(String)
}

/// The operations Lumen needs from a cloud record database, scoped to Lumen's own zone in the
/// user's private database. Implemented over CloudKit in `LumenPlatform`, and in memory for tests.
public protocol CloudRecordDatabase: Sendable {
    func zoneExists() async throws -> Bool
    /// Creates the zone. Creating an existing zone succeeds.
    func createZone() async throws
    /// The records that exist among `ids`; missing ones are absent from the result.
    func records(_ ids: [CloudRecordID]) async throws -> [CloudRecordID: CloudRecord]
    /// Saves records independently (not atomically). A record whose `systemFields` are stale
    /// comes back as `.conflict`. Whole-request failures (network, `limitExceeded`, …) throw.
    func save(_ records: [CloudRecord]) async throws -> [CloudRecordID: CloudSaveOutcome]
    /// Changes in the zone after `token` (`nil` = from the beginning), at most about `limit`
    /// records per page.
    func changes(since token: Data?, limit: Int) async throws -> CloudChangeBatch
}

/// CloudKit's documented request limits, plus Lumen's own headroom.
public enum CloudLimits {
    /// Records per modify request.
    public static let maximumRecordsPerRequest = 400
    /// Inline bytes per modify request (CloudKit allows about 2 MB).
    public static let maximumRequestBytes = 1_500_000
    /// Encoded entity states larger than this are stored as an asset instead of a field, keeping
    /// the record well under CloudKit's 1 MB record limit.
    public static let inlineStateLimit = 200_000
}
