import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenAutomation
import LumenSync
import LumenApplication
import LumenTestSupport

/// A remote shared by several app instances: an ordered log of envelopes plus files by hash.
final class MemoryRemote: SyncTransport, BlobTransport {
    private let log = Mutex<[SyncEnvelope]>([])
    private let files = Mutex<[String: Data]>([:])

    var envelopes: [SyncEnvelope] { log.withLock { $0 } }
    var fileCount: Int { files.withLock { $0.count } }

    func push(_ envelopes: [SyncEnvelope]) async throws {
        log.withLock { $0.append(contentsOf: envelopes) }
    }

    func pull(after cursor: String?, limit: Int) async throws -> PullResult {
        let all = envelopes
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(all.count, start + limit)
        return PullResult(envelopes: start < end ? Array(all[start..<end]) : [], cursor: String(end), hasMore: end < all.count)
    }

    func containsBlob(sha256: String) async throws -> Bool { files.withLock { $0[sha256] != nil } }
    func uploadBlob(_ data: Data, sha256: String) async throws { files.withLock { $0[sha256] = data } }
    func downloadBlob(sha256: String) async throws -> Data? { files.withLock { $0[sha256] } }
}

/// A Lumen whose runtime has not been started, as when the system launches the app in the
/// background.
private struct ColdApp {
    let services: LumenServices
    let runtime: LumenRuntime
    let directory: URL

    static func make(remote: MemoryRemote?, clock: ManualTimeSource = ManualTimeSource()) async throws -> ColdApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-background-\(UUID().uuidString)")
        var platform = PlatformServices.ephemeral()
        platform.syncTransport = remote
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: clock,
            calendar: .testUTC
        )
        return ColdApp(services: services, runtime: LumenRuntime(services: services), directory: directory)
    }

    func tearDown() async {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory) // best-effort cleanup of a scratch directory
    }
}

@Suite("Background refresh")
struct BackgroundRefreshTests {
    @Test("a background launch starts the runtime, runs due automations and syncs what they did")
    func backgroundLaunch() async throws {
        let clock = ManualTimeSource()
        let remote = MemoryRemote()
        let app = try await ColdApp.make(remote: remote, clock: clock)
        #expect(await !app.runtime.isStarted)

        let first = await app.runtime.performBackgroundRefresh()
        #expect(await app.runtime.isStarted)
        #expect(first.completed == BackgroundRefreshReport.Step.allCases)
        #expect(first.syncOutcome == .succeeded)

        let services = app.services
        let trigger = WorkflowNode(title: "Every morning", kind: .trigger)
        let action = WorkflowNode(title: "Note it", kind: .action(actionID: "knowledge.createNote", parameters: [
            "title": .literal("Morning log"),
            "body": .literal("Written in the background"),
        ]))
        _ = try await services.automation.engine.create(WorkflowDraft(
            name: "Morning",
            trigger: .schedule(ScheduleTrigger(rule: .daily, anchor: services.today, time: try #require(TimeOfDay(hour: 10, minute: 0)))),
            graph: WorkflowGraph(nodes: [trigger, action], edges: [WorkflowEdge(from: trigger.id, to: action.id)])
        ))

        clock.advance(by: 2 * 3_600)
        let second = await app.runtime.performBackgroundRefresh()
        #expect(second.isComplete)
        #expect(second.syncOutcome == .succeeded)
        let note = try #require(try await services.knowledge.notes.resolveTitle("Morning log"))
        #expect(remote.envelopes.contains { $0.entity == note.reference })
        await app.tearDown()
    }

    @Test("out of time or cancelled, the remaining steps are skipped")
    func budget() async throws {
        let clock = ManualTimeSource()
        let app = try await ColdApp.make(remote: nil, clock: clock)

        let late = await app.runtime.performBackgroundRefresh(deadline: clock.now())
        #expect(late.completed.isEmpty)
        #expect(late.skipped == BackgroundRefreshReport.Step.allCases)
        #expect(!late.isComplete)

        let runtime = app.runtime
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runtime.performBackgroundRefresh()
        }.value
        #expect(cancelled.skipped == BackgroundRefreshReport.Step.allCases)

        let unhurried = await app.runtime.performBackgroundRefresh(deadline: clock.now().addingTimeInterval(30))
        #expect(unhurried.isComplete)
        // Without a sync service, the sync step runs and reports that it had nothing to do.
        #expect(unhurried.syncOutcome == .skipped)
        await app.tearDown()
    }

    @Test("document files follow their documents to other devices")
    func documentFiles() async throws {
        let remote = MemoryRemote()
        let a = try await ColdApp.make(remote: remote)
        let b = try await ColdApp.make(remote: remote)
        let bytes = Data("Quarterly numbers".utf8)
        let document = try await a.services.knowledge.documents.import(data: bytes, fileName: "numbers.txt", contentType: "public.plain-text")

        #expect(await a.runtime.performBackgroundRefresh().isComplete)
        #expect(remote.fileCount == 1)
        // Uploads are remembered per file.
        #expect(await a.services.documentFiles.uploadPending().uploaded == 0)

        #expect(await b.runtime.performBackgroundRefresh().isComplete)
        let synced = try #require(try await b.services.knowledge.documents.document(document.id))
        #expect(synced.sha256 == document.sha256)
        // The file isn't on B until it is read; reading downloads and verifies it.
        #expect(try await b.services.knowledge.documents.data(for: document.id) == bytes)

        await a.tearDown()
        await b.tearDown()
    }

    @Test("without sync, a document whose file is missing reports it instead of fetching")
    func noTransport() async throws {
        let app = try await ColdApp.make(remote: nil)
        #expect(!app.services.documentFiles.isConfigured)
        #expect(await app.services.documentFiles.uploadPending() == BlobUploadReport())
        await app.tearDown()
    }
}
