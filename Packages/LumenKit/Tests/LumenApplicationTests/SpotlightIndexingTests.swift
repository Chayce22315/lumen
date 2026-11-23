import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenApplication
import LumenTestSupport

/// An in-memory system search index that records its calls.
final class FakeSystemIndex: SystemSearchIndexing {
    private let items = Mutex<[String: SystemSearchItem]>([:])
    private let calls = Mutex<[String]>([])
    let failing = Mutex(false)

    struct Unavailable: Error {}

    func index(_ batch: [SystemSearchItem]) async throws {
        try check()
        calls.withLock { $0.append("index \(batch.count)") }
        items.withLock { stored in for item in batch { stored[item.identifier] = item } }
    }

    func remove(identifiers: [String]) async throws {
        try check()
        calls.withLock { $0.append("remove \(identifiers.count)") }
        items.withLock { stored in for identifier in identifiers { stored[identifier] = nil } }
    }

    func removeAll() async throws {
        try check()
        calls.withLock { $0.append("removeAll") }
        items.withLock { $0.removeAll() }
    }

    private func check() throws {
        if failing.withLock({ $0 }) { throw Unavailable() }
    }

    var stored: [String: SystemSearchItem] { items.withLock { $0 } }
    var log: [String] { calls.withLock { $0 } }
    func clearLog() { calls.withLock { $0.removeAll() } }
}

struct SpotlightApp {
    let services: LumenServices
    let runtime: LumenRuntime
    let index: FakeSystemIndex?
    let directory: URL

    static func make(index: FakeSystemIndex? = FakeSystemIndex(), started: Bool = true) async throws -> SpotlightApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-spotlight-\(UUID().uuidString)")
        var platform = PlatformServices.ephemeral()
        platform.systemSearchIndex = index
        let services = try await LumenBootstrap.make(
            configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
            platform: platform,
            timeSource: ManualTimeSource(),
            calendar: .testUTC
        )
        let runtime = LumenRuntime(services: services)
        if started { await runtime.start() }
        return SpotlightApp(services: services, runtime: runtime, index: index, directory: directory)
    }

    var indexer: SystemSearchIndexer { services.spotlight }

    func tearDown() async {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory) // best-effort cleanup of a scratch directory
    }
}

@Suite("Spotlight indexing")
struct SpotlightIndexingTests {
    @Test("open tasks and unarchived notes become short items; the rest are left out")
    func items() throws {
        let now = ManualTimeSource.referenceDate
        var task = TaskItem(title: "Call the plumber", notes: "Ask about   the\nboiler", dueDate: CalendarDate("2026-11-23"), tags: ["home"], createdAt: now, updatedAt: now)
        let item = try #require(SystemSearchItems.item(for: task, calendar: .testUTC))
        #expect(item.identifier == "task:\(task.id.uuidString)")
        #expect(item.domain == "app.lumen.task")
        #expect(item.title == "Call the plumber")
        #expect(item.snippet == "Due Nov 23, 2026 · Ask about the boiler")
        #expect(item.keywords == ["home"])
        task.status = .done
        #expect(SystemSearchItems.item(for: task, calendar: .testUTC) == nil)

        let long = String(repeating: "Long body text. ", count: 200)
        var note = Note(title: "", body: "# Heading\n\n" + long, createdAt: now, updatedAt: now)
        let noteItem = try #require(SystemSearchItems.item(for: note))
        #expect(noteItem.title == "Untitled note")
        #expect(noteItem.snippet.count <= SystemSearchItem.maximumSnippetLength)
        #expect(!noteItem.snippet.contains("#"))
        note.isArchived = true
        #expect(SystemSearchItems.item(for: note) == nil)
    }

    @Test("identifiers handed back by the system resolve to Lumen's own kinds only")
    func identifiers() {
        let id = UUID()
        #expect(SystemSearchItem.reference(fromIdentifier: "task:\(id.uuidString)") == EntityReference(kind: .task, id: id))
        #expect(SystemSearchItem.reference(fromIdentifier: "note:\(id.uuidString)") == EntityReference(kind: .note, id: id))
        #expect(SystemSearchItem.reference(fromIdentifier: "workflow:\(id.uuidString)") == nil)
        #expect(SystemSearchItem.reference(fromIdentifier: "garbage") == nil)
    }

    @Test("the first launch indexes existing tasks and notes once")
    func firstLaunch() async throws {
        let app = try await SpotlightApp.make(started: false)
        let index = try #require(app.index)
        let task = try await app.services.organization.tasks.create(TaskDraft(title: "Existing task"))
        let note = try await app.services.knowledge.notes.create(title: "Existing note", body: "Body")
        await app.runtime.start()
        await app.indexer.waitUntilIdle()
        #expect(Set(index.stored.keys) == [task.reference.uri, note.reference.uri])
        #expect(await app.services.settings.value(SystemSearchIndexer.indexVersionKey) == SystemSearchIndexer.currentIndexVersion)

        // A rebuild happens only when the item format changes.
        index.clearLog()
        await app.indexer.rebuildIfNeeded()
        #expect(index.log.isEmpty)
        await app.tearDown()
    }

    @Test("changes are written in batches: completed, archived and deleted items leave the index")
    func incremental() async throws {
        let app = try await SpotlightApp.make()
        let index = try #require(app.index)
        await app.indexer.waitUntilIdle()
        index.clearLog()

        let tasks = app.services.organization.tasks
        let first = try await tasks.create(TaskDraft(title: "One"))
        let second = try await tasks.create(TaskDraft(title: "Two"))
        let third = try await tasks.create(TaskDraft(title: "Three"))
        await app.indexer.waitUntilIdle(events: 3)
        // One debounced batch for the burst.
        #expect(index.log == ["index 3"])
        #expect(index.stored[second.reference.uri]?.title == "Two")

        _ = try await tasks.complete(first.id)
        try await tasks.delete(third.id)
        _ = try await tasks.update(second.id, TaskChanges(title: "Two, renamed"))
        await app.indexer.waitUntilIdle(events: 6)
        #expect(Set(index.stored.keys) == [second.reference.uri])
        #expect(index.stored[second.reference.uri]?.title == "Two, renamed")

        _ = try await tasks.reopen(first.id)
        let note = try await app.services.knowledge.notes.create(title: "Recipe", body: "Flour, water, salt.")
        await app.indexer.waitUntilIdle(events: 8)
        #expect(index.stored[first.reference.uri] != nil)
        #expect(index.stored[note.reference.uri]?.snippet == "Flour, water, salt.")

        _ = try await app.services.knowledge.notes.archive(note.id)
        await app.indexer.waitUntilIdle(events: 9)
        #expect(index.stored[note.reference.uri] == nil)

        // Flushing writes at once instead of after the pause.
        let fourth = try await tasks.create(TaskDraft(title: "Four"))
        #expect(await eventually { await app.indexer.processedEventCount >= 10 })
        await app.indexer.flush()
        #expect(index.stored[fourth.reference.uri] != nil)
        await app.tearDown()
    }

    @Test("turning Spotlight off removes every item and ignores changes; on rebuilds")
    func toggle() async throws {
        let app = try await SpotlightApp.make()
        let index = try #require(app.index)
        await app.indexer.waitUntilIdle()
        _ = try await app.services.organization.tasks.create(TaskDraft(title: "Visible"))
        await app.indexer.waitUntilIdle(events: 1)
        #expect(index.stored.count == 1)

        try await app.indexer.setEnabled(false)
        #expect(await app.indexer.isEnabled() == false)
        #expect(index.stored.isEmpty)
        _ = try await app.services.organization.tasks.create(TaskDraft(title: "Private"))
        await app.indexer.waitUntilIdle(events: 2)
        #expect(index.stored.isEmpty)
        #expect(await app.indexer.rebuildAll() == nil)

        try await app.indexer.setEnabled(true)
        #expect(index.stored.count == 2)
        await app.tearDown()
    }

    @Test("a failed rebuild is retried on the next launch")
    func failedRebuild() async throws {
        let index = FakeSystemIndex()
        index.failing.withLock { $0 = true }
        let app = try await SpotlightApp.make(index: index, started: false)
        _ = try await app.services.organization.tasks.create(TaskDraft(title: "Waiting"))
        #expect(await app.indexer.rebuildAll() == nil)
        #expect(await app.services.settings.value(SystemSearchIndexer.indexVersionKey) == 0)
        index.failing.withLock { $0 = false }
        await app.indexer.rebuildIfNeeded()
        #expect(index.stored.count == 1)
        #expect(await app.services.settings.value(SystemSearchIndexer.indexVersionKey) == SystemSearchIndexer.currentIndexVersion)
        await app.tearDown()
    }

    @Test("without a system index nothing is indexed and the setting is unavailable")
    func unavailable() async throws {
        let app = try await SpotlightApp.make(index: nil)
        #expect(!app.indexer.isAvailable)
        _ = try await app.services.organization.tasks.create(TaskDraft(title: "Nowhere"))
        #expect(await app.indexer.rebuildAll() == nil)
        await app.tearDown()
    }
}
