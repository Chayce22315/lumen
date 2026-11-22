import Foundation
import LumenFoundation

public enum CloudRecordCodecError: Error, Hashable, Sendable {
    case missingField(String)
    case unsupportedFormat(Int64)
    case invalidEntity(String)
}

/// Maps entity states and document blobs to cloud records and back. Pure: no I/O.
///
/// One record per entity holds the entity's merged `EntityState` (JSON). States above
/// `CloudLimits.inlineStateLimit` bytes go into an asset so the record stays small.
public enum CloudRecordCodec {
    public static let entityRecordType = "LumenEntity"
    public static let blobRecordType = "LumenBlob"
    public static let formatVersion: Int64 = 1
    /// The origin of a record whose state combines writes of several replicas: every replica
    /// applies it when pulling (applying is idempotent).
    public static let mergedOrigin = "cloud"

    enum Field {
        static let kind = "kind"
        static let entityID = "entityID"
        static let format = "format"
        static let origin = "origin"
        static let state = "state"
        static let stateAsset = "stateAsset"
        static let sha256 = "sha256"
        static let byteCount = "byteCount"
        static let data = "data"
    }

    // MARK: Entities

    public static func recordID(for entity: EntityReference) -> CloudRecordID {
        CloudRecordID("entity.\(entity.kind.rawValue).\(entity.id.uuidString.lowercased())")
    }

    /// The record for `state`, keeping the server metadata of `existing` so the save is checked
    /// against the version that was read.
    public static func record(
        for entity: EntityReference,
        state: EntityState,
        origin: String,
        existing: CloudRecord?,
        inlineLimit: Int = CloudLimits.inlineStateLimit
    ) throws -> CloudRecord {
        let encoded = try JSONCoding.encoder.encode(state)
        var fields: [String: CloudValue] = [
            Field.kind: .string(entity.kind.rawValue),
            Field.entityID: .string(entity.id.uuidString.lowercased()),
            Field.format: .int64(formatVersion),
            Field.origin: .string(origin),
        ]
        let cleared: Set<String>
        if encoded.count > inlineLimit {
            fields[Field.stateAsset] = .asset(encoded)
            cleared = [Field.state]
        } else {
            fields[Field.state] = .bytes(encoded)
            cleared = [Field.stateAsset]
        }
        return CloudRecord(
            id: recordID(for: entity),
            type: entityRecordType,
            fields: fields,
            clearedFields: cleared,
            systemFields: existing?.systemFields
        )
    }

    public static func isEntityRecord(_ record: CloudRecord) -> Bool {
        record.type == entityRecordType
    }

    /// The entity state stored in a record.
    public static func state(of record: CloudRecord) throws -> EntityState {
        try checkFormat(record)
        guard let data = record.fields[Field.state]?.dataValue ?? record.fields[Field.stateAsset]?.dataValue else {
            throw CloudRecordCodecError.missingField(Field.state)
        }
        return try JSONCoding.decoder.decode(EntityState.self, from: data)
    }

    public static func envelope(from record: CloudRecord) throws -> SyncEnvelope {
        try checkFormat(record)
        guard let kind = record.fields[Field.kind]?.stringValue, !kind.isEmpty else {
            throw CloudRecordCodecError.missingField(Field.kind)
        }
        guard let idText = record.fields[Field.entityID]?.stringValue else {
            throw CloudRecordCodecError.missingField(Field.entityID)
        }
        guard let id = UUID(uuidString: idText) else {
            throw CloudRecordCodecError.invalidEntity(idText)
        }
        let origin = record.fields[Field.origin]?.stringValue ?? mergedOrigin
        return SyncEnvelope(entity: EntityReference(kind: EntityKind(rawValue: kind), id: id), state: try state(of: record), origin: origin)
    }

    private static func checkFormat(_ record: CloudRecord) throws {
        let format = record.fields[Field.format]?.int64Value ?? formatVersion
        guard format <= formatVersion else { throw CloudRecordCodecError.unsupportedFormat(format) }
    }

    // MARK: Blobs

    public static func blobRecordID(sha256: String) -> CloudRecordID {
        CloudRecordID("blob.\(sha256.lowercased())")
    }

    public static func blobRecord(data: Data, sha256: String) -> CloudRecord {
        CloudRecord(
            id: blobRecordID(sha256: sha256),
            type: blobRecordType,
            fields: [
                Field.sha256: .string(sha256.lowercased()),
                Field.byteCount: .int64(Int64(data.count)),
                Field.data: .asset(data),
            ]
        )
    }

    public static func blobData(of record: CloudRecord) throws -> Data {
        guard let data = record.fields[Field.data]?.dataValue else {
            throw CloudRecordCodecError.missingField(Field.data)
        }
        return data
    }
}
