import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenSync
import LumenTestSupport

/// A stand-in content hash (FNV-1a, lowercase hex): the synchronizer only needs a stable digest.
let testDigest: @Sendable (Data) -> String = { data in
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(hash, radix: 16)
}

private func cloudTransport(_ cloud: InMemoryCloudDatabase) -> CloudSyncTransport {
    CloudSyncTransport(database: cloud, logger: LogCapture().makeSystem().logger("cloud"))
}

private func cloudReplica(_ cloud: InMemoryCloudDatabase, clock: ManualTimeSource = ManualTimeSource()) async throws -> Replica {
    try await Replica.make(transport: cloudTransport(cloud), clock: clock, batchSize: 50)
}

private func memoEnvelope(_ index: Int, replica: String = "a") -> SyncEnvelope {
    let stamp = HybridTimestamp(milliseconds: Int64(index + 1), counter: 0, replica: replica)
    return SyncEnvelope(
        entity: EntityReference(kind: .memo, id: UUID()),
        state: EntityState(fields: ["title": FieldState(value: .string("Memo \(index)"), timestamp: stamp)]),
        origin: replica
    )
}

@Suite("Cloud records")
struct CloudRecordCodecTests {
    @Test("entity states round-trip through records, inline and as assets")
    func roundTrip() throws {
        let entity = EntityReference(kind: .memo, id: UUID())
        let stamp = HybridTimestamp(milliseconds: 1_000, counter: 2, replica: "a")
        let state = EntityState(
            fields: ["title": FieldState(value: .string("Hello"), timestamp: stamp), "pinned": FieldState(value: nil, timestamp: stamp)],
            tombstone: nil
        )

        let inline = try CloudRecordCodec.record(for: entity, state: state, origin: "a", existing: nil)
        #expect(inline.id == CloudRecordCodec.recordID(for: entity))
        #expect(inline.fields["state"] != nil)
        #expect(inline.fields["stateAsset"] == nil)
        #expect(inline.clearedFields == ["stateAsset"])
        #expect(try CloudRecordCodec.envelope(from: inline) == SyncEnvelope(entity: entity, state: state, origin: "a"))

        let large = try CloudRecordCodec.record(for: entity, state: state, origin: "a", existing: inline, inlineLimit: 10)
        guard case .asset? = large.fields["stateAsset"] else {
            Issue.record("A state above the inline limit should be an asset")
            return
        }
        #expect(large.fields["state"] == nil)
        #expect(large.clearedFields == ["state"])
        #expect(try CloudRecordCodec.state(of: large) == state)

        var future = inline
        future.fields["format"] = .int64(99)
        #expect(throws: CloudRecordCodecError.unsupportedFormat(99)) { try CloudRecordCodec.envelope(from: future) }
        var anonymous = inline
        anonymous.fields["kind"] = nil
        #expect(throws: CloudRecordCodecError.missingField("kind")) { try CloudRecordCodec.envelope(from: anonymous) }
    }

    @Test("requests respect the record count and byte limits")
    func batching() {
        #expect(CloudBatching.chunks(Array(0..<950), maximumCount: 400).map(\.count) == [400, 400, 150])
        let records = (0..<5).map { CloudRecord(id: CloudRecordID("r\($0)"), type: "T", fields: ["b": .bytes(Data(count: 100))]) }
        #expect(CloudBatching.requests(records, maximumCount: 10, maximumBytes: 250).map(\.count) == [2, 2, 1])
        #expect(CloudBatching.requests(records, maximumCount: 3, maximumBytes: 10_000).map(\.count) == [3, 2])
        // A record over the byte budget still gets a request of its own.
        let big = CloudRecord(id: CloudRecordID("big"), type: "T", fields: ["b": .bytes(Data(count: 1_000))])
        #expect(CloudBatching.requests([big], maximumCount: 10, maximumBytes: 250).map(\.count) == [1])
    }
}

@Suite("Cloud sync transport")
struct CloudSyncTransportTests {
    @Test("two devices converge through the cloud, including concurrent edits to different fields")
    func convergence() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await cloudReplica(cloud)
        let b = try await cloudReplica(cloud)
        let id = UUID()
        let memo = Memo(id: id, title: "Plan", body: "Draft", pinned: true)
        try await a.save(memo)
        let first = await a.engine.synchronize()
        #expect(first.outcome == .succeeded)
        #expect(first.pushed == 1)
        #expect(cloud.zoneExistsNow)
        #expect(await b.engine.synchronize().pulled == 1)
        #expect(try await b.memo(id) == memo)

        a.clock.advance(by: 10)
        try await a.save(Memo(id: id, title: "Plan v2", body: "Draft", pinned: true))
        b.clock.advance(by: 20)
        try await b.save(Memo(id: id, title: "Plan", body: "Final body", pinned: true))
        await a.engine.synchronize()
        await b.engine.synchronize()
        await a.engine.synchronize()

        let expected = Memo(id: id, title: "Plan v2", body: "Final body", pinned: true)
        #expect(try await a.memo(id) == expected)
        #expect(try await b.memo(id) == expected)
        #expect(try await a.engine.conflicts().isEmpty)
        #expect(try await b.engine.conflicts().isEmpty)
        // A device doesn't re-apply a record holding only its own write.
        #expect(await a.engine.synchronize().pulled == 0)
    }

    @Test("large pushes are sent in requests of at most 400 records")
    func requestLimit() async throws {
        let cloud = InMemoryCloudDatabase()
        let transport = cloudTransport(cloud)
        try await transport.prepare(hasSynchronizedBefore: false)
        try await transport.push((0..<950).map { memoEnvelope($0) })
        #expect(cloud.recordCount == 950)
        #expect(cloud.saveRequestSizes.allSatisfy { $0 <= 400 })
        #expect(cloud.saveRequestSizes.reduce(0, +) == 950)
    }

    @Test("a request the service finds too large is split and retried")
    func limitExceeded() async throws {
        let cloud = InMemoryCloudDatabase(maximumRecordsPerSave: 3)
        let transport = cloudTransport(cloud)
        try await transport.prepare(hasSynchronizedBefore: false)
        try await transport.push((0..<10).map { memoEnvelope($0) })
        #expect(cloud.recordCount == 10)
        #expect(cloud.saveRequestSizes.allSatisfy { $0 <= 3 })
    }

    @Test("a save racing another device's write is merged, not overwritten")
    func racingSave() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await cloudReplica(cloud)
        let id = UUID()
        let entity = EntityReference(kind: .memo, id: id)
        let recordID = CloudRecordCodec.recordID(for: entity)
        try await a.save(Memo(id: id, title: "Plan", body: "", pinned: nil))
        await a.engine.synchronize()

        a.clock.advance(by: 10)
        try await a.save(Memo(id: id, title: "Plan v2", body: "", pinned: nil))
        // Another device saves a newer body between A reading the record and A saving it.
        cloud.onNextSave {
            guard let current = cloud.record(recordID), var state = try? CloudRecordCodec.state(of: current) else { return }
            state.fields["body"] = FieldState(value: .string("From B"), timestamp: HybridTimestamp(milliseconds: 9_000_000_000_000, counter: 0, replica: "b"))
            if let record = try? CloudRecordCodec.record(for: entity, state: state, origin: "b", existing: current) {
                cloud.forceWrite(record)
            }
        }
        let run = await a.engine.synchronize()
        #expect(run.outcome == .succeeded)

        let server = try CloudRecordCodec.state(of: try #require(cloud.record(recordID)))
        #expect(server.fields["title"]?.value == .string("Plan v2"))
        #expect(server.fields["body"]?.value == .string("From B"))
        // The merged record is marked as such, so A applies B's body when it pulls.
        #expect(try await a.memo(id)?.body == "From B")
        #expect(try await a.memo(id)?.title == "Plan v2")
    }

    @Test("an expired change token falls back to reading everything again")
    func expiredToken() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await cloudReplica(cloud)
        let b = try await cloudReplica(cloud)
        let first = Memo(id: UUID(), title: "First", body: "", pinned: nil)
        try await a.save(first)
        await a.engine.synchronize()
        await b.engine.synchronize()

        cloud.expireTokens()
        let second = Memo(id: UUID(), title: "Second", body: "", pinned: nil)
        try await a.save(second)
        #expect(await a.engine.synchronize().outcome == .succeeded)
        let run = await b.engine.synchronize()
        #expect(run.outcome == .succeeded)
        #expect(try await b.memo(second.id) == second)
        #expect(try await b.memo(first.id) == first)
    }

    @Test("after the cloud data is deleted, a device uploads everything it knows again")
    func remoteReset() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await cloudReplica(cloud)
        let b = try await cloudReplica(cloud)
        let fromA = Memo(id: UUID(), title: "From A", body: "", pinned: nil)
        let fromB = Memo(id: UUID(), title: "From B", body: "", pinned: nil)
        try await a.save(fromA)
        await a.engine.synchronize()
        try await b.save(fromB)
        await b.engine.synchronize()
        await a.engine.synchronize()

        // Mid-session: A's next pull finds the zone gone, and A rebuilds it from its shadows,
        // including B's memo.
        cloud.deleteZone()
        let run = await a.engine.synchronize()
        #expect(run.outcome == .succeeded)
        #expect(run.pushed == 2)
        #expect(cloud.zoneExistsNow)
        #expect(cloud.recordCount == 2)

        let newDevice = try await cloudReplica(cloud)
        await newDevice.engine.synchronize()
        #expect(try await newDevice.memo(fromA.id) == fromA)
        #expect(try await newDevice.memo(fromB.id) == fromB)
        #expect(await b.engine.synchronize().outcome == .succeeded)
    }

    @Test("at launch, a missing zone is a reset only for a device that synchronized before")
    func zoneCheckAtLaunch() async throws {
        let cloud = InMemoryCloudDatabase()
        let returning = cloudTransport(cloud)
        await #expect(throws: SyncTransportError.remoteReset) { try await returning.prepare(hasSynchronizedBefore: true) }
        #expect(cloud.zoneExistsNow)
        // The zone exists now, so the retry after the reset goes through.
        try await returning.prepare(hasSynchronizedBefore: false)

        cloud.deleteZone()
        let firstLaunch = cloudTransport(cloud)
        try await firstLaunch.prepare(hasSynchronizedBefore: false)
        #expect(cloud.zoneExistsNow)
    }

    @Test("cloud errors map to sync states")
    func errorMapping() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await cloudReplica(cloud)
        try await a.save(Memo(id: UUID(), title: "Offline edit", body: "", pinned: nil))

        cloud.fail(with: [.network])
        #expect(await a.engine.synchronize().outcome == .offline)

        cloud.fail(with: [.notAuthenticated])
        #expect(await a.engine.synchronize().outcome == .failed)
        guard case .failed(let unauthorized) = await a.engine.status().state else {
            Issue.record("Expected a failed state")
            return
        }
        #expect(unauthorized.title == "Sign in again")

        cloud.fail(with: [.quotaExceeded])
        #expect(await a.engine.synchronize().outcome == .failed)
        guard case .failed(let quota) = await a.engine.status().state else {
            Issue.record("Expected a failed state")
            return
        }
        #expect(quota.message == "Your iCloud storage is full.")

        // Temporary unavailability is retried within the run.
        cloud.fail(with: [.unavailable(retryAfter: 2)])
        let recovered = await a.engine.synchronize()
        #expect(recovered.outcome == .succeeded)
        #expect(recovered.pushed == 1)
    }

    @Test("pages holding only files don't end a pull early")
    func filePages() async throws {
        let cloud = InMemoryCloudDatabase()
        let transport = cloudTransport(cloud)
        try await transport.prepare(hasSynchronizedBefore: false)
        for index in 0..<5 {
            try await transport.uploadBlob(Data("file \(index)".utf8), sha256: "hash\(index)")
        }
        try await transport.push([memoEnvelope(0)])
        let result = try await transport.pull(after: nil, limit: 2)
        #expect(result.envelopes.count == 1)
        #expect(!result.hasMore)
    }
}

@Suite("Document file sync")
struct BlobSynchronizerTests {
    private func makeDatabase() async throws -> Database {
        let database = try Database(location: .inMemory, timeSource: ManualTimeSource())
        try await database.migrate([SyncEngine.schema])
        return database
    }

    private func synchronizer(_ transport: (any BlobTransport)?, database: Database) -> BlobSynchronizer {
        BlobSynchronizer(database: database, transport: transport, digest: testDigest, timeSource: ManualTimeSource(), logger: LogCapture().makeSystem().logger("blobs"))
    }

    @Test("files upload once per content, download verified, and pause when offline")
    func uploadAndDownload() async throws {
        let cloud = InMemoryCloudDatabase()
        let transport = cloudTransport(cloud)
        try await transport.prepare(hasSynchronizedBefore: false)
        let blobs = synchronizer(transport, database: try await makeDatabase())

        let alpha = Data("alpha".utf8)
        let beta = Data("beta".utf8)
        let files = ["a.txt": alpha, "a-copy.txt": alpha, "b.txt": beta]
        let references = [
            BlobReference(sha256: testDigest(alpha), storageKey: "a.txt"),
            BlobReference(sha256: testDigest(alpha), storageKey: "a-copy.txt"),
            BlobReference(sha256: testDigest(beta), storageKey: "b.txt"),
        ]
        let reads = Mutex(0)
        let read: @Sendable (BlobReference) async throws -> Data = { reference in
            reads.withLock { $0 += 1 }
            guard let data = files[reference.storageKey] else { throw BlobSyncError.notFound }
            return data
        }
        let report = await blobs.uploadPending(references, read: read)
        #expect(report.uploaded == 2)
        #expect(reads.withLock { $0 } == 2)
        #expect(await blobs.uploadPending(references, read: read) == BlobUploadReport())

        // Another device downloads by hash.
        let other = synchronizer(transport, database: try await makeDatabase())
        #expect(try await other.download(sha256: testDigest(alpha)) == alpha)
        await #expect(throws: BlobSyncError.notFound) { try await other.download(sha256: "0123") }
        cloud.forceWrite(CloudRecordCodec.blobRecord(data: Data("tampered".utf8), sha256: testDigest(beta)))
        await #expect(throws: BlobSyncError.corrupted) { try await other.download(sha256: testDigest(beta)) }

        // A local file that no longer matches its hash is not spread.
        let gamma = BlobReference(sha256: testDigest(Data("gamma".utf8)), storageKey: "c.txt")
        let damaged = await blobs.uploadPending([gamma]) { _ in Data("not gamma".utf8) }
        #expect(damaged.failed == 1)
        #expect(damaged.uploaded == 0)

        // Offline pauses the remaining uploads until next time.
        cloud.fail(with: [.network])
        let delta = Data("delta".utf8)
        let paused = await blobs.uploadPending([BlobReference(sha256: testDigest(delta), storageKey: "d.txt")]) { _ in delta }
        #expect(paused.stoppedEarly)
        #expect(paused.uploaded == 0)
        let resumed = await blobs.uploadPending([BlobReference(sha256: testDigest(delta), storageKey: "d.txt")]) { _ in delta }
        #expect(resumed.uploaded == 1)
    }

    @Test("without a transport nothing uploads and downloads explain why")
    func notConfigured() async throws {
        let blobs = synchronizer(nil, database: try await makeDatabase())
        #expect(!blobs.isConfigured)
        let report = await blobs.uploadPending([BlobReference(sha256: "ab", storageKey: "x")]) { _ in Data() }
        #expect(report == BlobUploadReport())
        await #expect(throws: BlobSyncError.notConfigured) { try await blobs.download(sha256: "ab") }
    }
}
