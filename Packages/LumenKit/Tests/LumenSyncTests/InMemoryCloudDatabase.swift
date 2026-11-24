import Foundation
import Synchronization
import LumenSync

/// A stand-in for CloudKit's private database with one custom zone: change tags (saves with stale
/// metadata conflict), a change feed with tokens, request limits, token expiry and zone deletion.
final class InMemoryCloudDatabase: CloudRecordDatabase {
    private struct Stored {
        var record: CloudRecord
        var version: Int
    }

    private struct State {
        var zoneExists = false
        var records: [CloudRecordID: Stored] = [:]
        /// (sequence, record) for every save, in order.
        var log: [(sequence: Int, id: CloudRecordID)] = []
        var sequence = 0
        /// Tokens carry the epoch they were issued in; expiring tokens starts a new epoch.
        var epoch = 0
        var saveRequestSizes: [Int] = []
        var failures: [CloudDatabaseError] = []
    }

    private let state = Mutex(State())
    /// Requests with more records than this fail with `limitExceeded`.
    let maximumRecordsPerSave: Int
    /// Runs once before the next save, e.g. to simulate another device saving first.
    private let beforeNextSave = Mutex<(@Sendable () -> Void)?>(nil)

    init(maximumRecordsPerSave: Int = CloudLimits.maximumRecordsPerRequest) {
        self.maximumRecordsPerSave = maximumRecordsPerSave
    }

    // MARK: Test controls

    var saveRequestSizes: [Int] { state.withLock { $0.saveRequestSizes } }
    var recordCount: Int { state.withLock { $0.records.count } }
    var zoneExistsNow: Bool { state.withLock { $0.zoneExists } }

    func record(_ id: CloudRecordID) -> CloudRecord? {
        state.withLock { $0.records[id]?.record }
    }

    func fail(with errors: [CloudDatabaseError]) {
        state.withLock { $0.failures.append(contentsOf: errors) }
    }

    /// Every token handed out so far stops working.
    func expireTokens() {
        state.withLock { $0.epoch += 1 }
    }

    /// What "delete iCloud data" does: the zone and everything in it disappear.
    func deleteZone() {
        state.withLock {
            $0.zoneExists = false
            $0.records = [:]
            $0.log = []
            $0.epoch += 1
        }
    }

    func onNextSave(_ action: @escaping @Sendable () -> Void) {
        beforeNextSave.withLock { $0 = action }
    }

    /// Writes as another device would, bypassing change tags.
    func forceWrite(_ record: CloudRecord) {
        state.withLock { state in
            state.sequence += 1
            let version = (state.records[record.id]?.version ?? 0) + 1
            var stored = record
            stored.systemFields = Data("v\(version)".utf8)
            state.records[record.id] = Stored(record: stored, version: version)
            state.log.append((state.sequence, record.id))
        }
    }

    // MARK: CloudRecordDatabase

    func zoneExists() async throws -> Bool {
        try state.withLock { state in
            try Self.takeFailure(&state)
            return state.zoneExists
        }
    }

    func createZone() async throws {
        try state.withLock { state in
            try Self.takeFailure(&state)
            state.zoneExists = true
        }
    }

    func records(_ ids: [CloudRecordID]) async throws -> [CloudRecordID: CloudRecord] {
        try state.withLock { state in
            try Self.takeFailure(&state)
            guard state.zoneExists else { throw CloudDatabaseError.zoneNotFound }
            var found: [CloudRecordID: CloudRecord] = [:]
            for id in ids {
                if let stored = state.records[id] { found[id] = stored.record }
            }
            return found
        }
    }

    func save(_ records: [CloudRecord]) async throws -> [CloudRecordID: CloudSaveOutcome] {
        if let hook = beforeNextSave.withLock({ value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }) {
            hook()
        }
        return try state.withLock { state in
            try Self.takeFailure(&state)
            guard state.zoneExists else { throw CloudDatabaseError.zoneNotFound }
            guard records.count <= maximumRecordsPerSave else { throw CloudDatabaseError.limitExceeded }
            state.saveRequestSizes.append(records.count)
            var outcomes: [CloudRecordID: CloudSaveOutcome] = [:]
            for record in records {
                let current = state.records[record.id]
                if let current, record.systemFields != current.record.systemFields {
                    outcomes[record.id] = .conflict(server: current.record)
                    continue
                }
                var fields = current?.record.fields ?? [:]
                for key in record.clearedFields { fields[key] = nil }
                fields.merge(record.fields) { _, new in new }
                let version = (current?.version ?? 0) + 1
                let saved = CloudRecord(id: record.id, type: record.type, fields: fields, systemFields: Data("v\(version)".utf8))
                state.sequence += 1
                state.records[record.id] = Stored(record: saved, version: version)
                state.log.append((state.sequence, record.id))
                outcomes[record.id] = .saved(saved)
            }
            return outcomes
        }
    }

    func changes(since token: Data?, limit: Int) async throws -> CloudChangeBatch {
        try state.withLock { state in
            try Self.takeFailure(&state)
            guard state.zoneExists else { throw CloudDatabaseError.zoneNotFound }
            let start: Int
            if let token {
                let parts = String(decoding: token, as: UTF8.self).split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, parts[0] == state.epoch else { throw CloudDatabaseError.changeTokenExpired }
                start = parts[1]
            } else {
                start = 0
            }
            var included: [CloudRecordID] = []
            var position = start
            for entry in state.log where entry.sequence > start {
                if included.count >= limit { break }
                if !included.contains(entry.id) { included.append(entry.id) }
                position = entry.sequence
            }
            let moreComing = state.log.contains { $0.sequence > position }
            let changed = included.compactMap { state.records[$0]?.record }
            let token = Data("\(state.epoch):\(max(position, start))".utf8)
            return CloudChangeBatch(changed: changed, deleted: [], token: token, moreComing: moreComing)
        }
    }

    private static func takeFailure(_ state: inout State) throws {
        if !state.failures.isEmpty {
            throw state.failures.removeFirst()
        }
    }
}
