import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge

/// Keeps the system search index (Spotlight) in step with tasks and notes.
///
/// Changes arrive as domain events; the entities they name are collected and written in batches
/// a moment later (or as soon as a batch is full), each re-read from storage, so a burst of edits
/// costs one index call. Open tasks and notes that are not archived are indexed; completed,
/// cancelled, archived and deleted ones are removed. The whole index is rebuilt when
/// `currentIndexVersion` is raised (what an item contains changed) and when the user turns
/// "Show in Spotlight" back on; turning it off removes every Lumen item. Writes, rebuilds and
/// removals run one at a time, in order, so a rebuild never overwrites a newer change. Like the
/// in-app search index it is a cache: a failed update is logged, and the entity is written again
/// on its next change or rebuild.
public actor SystemSearchIndexer {
    /// The user's "Show in Spotlight" switch.
    public static let enabledKey = SettingKey("spotlight.enabled", default: true)
    /// Which item format was last written in full; a lower value triggers a rebuild.
    public static let indexVersionKey = SettingKey("spotlight.indexVersion", default: 0)
    public static let currentIndexVersion = 1
    public static let indexedKinds: Set<EntityKind> = [.task, .note]
    /// Items per call to the system index.
    public static let batchSize = 100

    private let index: (any SystemSearchIndexing)?
    private let tasks: TaskService
    private let notes: NoteService
    private let settings: SettingsStore
    private let events: EventBus
    private let calendar: Calendar
    private let logger: Logger
    private let debounce: TimeInterval
    private var consumer: Task<Void, Never>?
    private var catchUp: Task<Void, Never>?
    private var flushing: Task<Void, Never>?
    /// The last queued unit of index work; units run one after another.
    private var tail: Task<Void, Never>?
    private var pending: Set<EntityReference> = []
    /// Set by `stop()`: a rebuild in progress stops between batches.
    private var isStopped = false
    /// Events received since `start()`, for deterministic waiting in tests.
    public private(set) var processedEventCount = 0

    public init(
        index: (any SystemSearchIndexing)?,
        tasks: TaskService,
        notes: NoteService,
        settings: SettingsStore,
        events: EventBus,
        calendar: Calendar,
        logger: Logger,
        debounce: TimeInterval = 0.5
    ) {
        self.index = index
        self.tasks = tasks
        self.notes = notes
        self.settings = settings
        self.events = events
        self.calendar = calendar
        self.logger = logger
        self.debounce = debounce
    }

    /// Whether this platform has a system search index at all.
    public nonisolated var isAvailable: Bool { index != nil }

    public func isEnabled() async -> Bool {
        await settings.value(Self.enabledKey)
    }

    // MARK: - Lifecycle

    /// Follows changes and, behind, rebuilds the index if its format changed. Idempotent; does
    /// nothing without a system index.
    public func start() {
        guard index != nil, consumer == nil else { return }
        isStopped = false
        let stream = events.events(matching: EventFilter(modules: ["organization", "knowledge", "sync"], entityKinds: Self.indexedKinds))
        consumer = Task { [weak self] in
            for await event in stream {
                guard let entity = event.entity else { continue }
                await self?.enqueue(entity)
            }
        }
        catchUp = Task(priority: .utility) { [weak self] in
            await self?.rebuildIfNeeded()
            await self?.finishCatchUp()
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        catchUp?.cancel()
        catchUp = nil
        flushing?.cancel()
        flushing = nil
        isStopped = true
    }

    // MARK: - The user's switch

    /// Turns "Show in Spotlight" on (rebuilding the index) or off (removing every Lumen item).
    public func setEnabled(_ enabled: Bool) async throws {
        try await settings.set(enabled, for: Self.enabledKey)
        guard index != nil else { return }
        if enabled {
            _ = await serially { await $0.performRebuild() }
            return
        }
        pending.removeAll()
        flushing?.cancel()
        flushing = nil
        let removal: Result<Void, any Error> = await serially { await $0.performRemoveAll() }
        try removal.get()
    }

    // MARK: - Rebuilding

    /// Rebuilds when the stored format is older than `currentIndexVersion` and indexing is on.
    public func rebuildIfNeeded() async {
        _ = await serially { indexer -> Int? in
            guard await indexer.settings.value(Self.indexVersionKey) < Self.currentIndexVersion else { return nil }
            return await indexer.performRebuild()
        }
    }

    /// Replaces everything Lumen has in the system index with the current tasks and notes.
    /// Returns the number of items written; `nil` when indexing is off or unavailable, or when it
    /// failed (a failed rebuild runs again on next launch).
    @discardableResult
    public func rebuildAll() async -> Int? {
        await serially { await $0.performRebuild() }
    }

    // MARK: - Incremental updates

    /// Writes collected changes now instead of after the debounce.
    public func flush() async {
        flushing?.cancel()
        flushing = nil
        await serially { await $0.write() }
    }

    /// Waits (bounded) until at least `count` events have been received, the launch catch-up has
    /// finished and nothing is waiting to be written.
    public func waitUntilIdle(events count: Int = 0, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processedEventCount >= count, catchUp == nil, flushing == nil, pending.isEmpty {
                let current = tail
                await current?.value
                if tail == current, flushing == nil, pending.isEmpty { return }
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000) // Polling pause; cancellation ends the wait early.
            }
        }
    }

    // MARK: - Internals

    /// Runs `work` after every unit queued before it and returns its result.
    private func serially<T: Sendable>(_ work: @escaping @Sendable (SystemSearchIndexer) async -> T) async -> T {
        let previous = tail
        let next = Task { [self] in
            await previous?.value
            return await work(self)
        }
        tail = Task { _ = await next.value }
        return await next.value
    }

    private func finishCatchUp() {
        catchUp = nil
    }

    private func enqueue(_ reference: EntityReference) {
        processedEventCount += 1
        guard Self.indexedKinds.contains(reference.kind) else { return }
        pending.insert(reference)
        let delay = pending.count >= Self.batchSize ? 0 : debounce
        guard delay == 0 || flushing == nil else { return }
        flushing?.cancel()
        flushing = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) // Cancelled when flushed early.
            }
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    private func flushNow() async {
        flushing = nil
        await serially { await $0.write() }
    }

    private func performRemoveAll() async -> Result<Void, any Error> {
        guard let index else { return .success(()) }
        do {
            try await index.removeAll()
            logger.notice("Spotlight items removed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func performRebuild() async -> Int? {
        guard let index, await isEnabled() else { return nil }
        // Everything is re-read below; changes collected so far are covered.
        pending.removeAll()
        do {
            let taskItems = try await tasks.tasks(.open).compactMap { SystemSearchItems.item(for: $0, calendar: calendar) }
            let noteItems = try await notes.allNotes().compactMap(SystemSearchItems.item(for:))
            let items = taskItems + noteItems
            try await index.removeAll()
            for batch in items.chunked(into: Self.batchSize) {
                // Stopped (shutdown): the version is not recorded, so the rebuild runs again next time.
                guard !isStopped else { return nil }
                try await index.index(batch)
            }
            try await settings.set(Self.currentIndexVersion, for: Self.indexVersionKey)
            logger.info("Spotlight index rebuilt", metadata: ["items": String(items.count)])
            return items.count
        } catch {
            logger.error("Spotlight index could not be rebuilt", error: error)
            return nil
        }
    }

    /// Re-reads every pending entity and writes or removes it, in batches.
    private func write() async {
        guard let index, !pending.isEmpty else { return }
        let references = pending
        pending.removeAll()
        guard await isEnabled() else { return }
        var items: [SystemSearchItem] = []
        var removed: [String] = []
        for reference in references.sorted(by: { $0.uri < $1.uri }) {
            do {
                if let item = try await item(for: reference) {
                    items.append(item)
                } else {
                    removed.append(reference.uri)
                }
            } catch {
                logger.error("Spotlight item could not be read", error: error, metadata: ["kind": reference.kind.rawValue])
            }
        }
        do {
            for batch in items.chunked(into: Self.batchSize) {
                try await index.index(batch)
            }
            for batch in removed.chunked(into: Self.batchSize) {
                try await index.remove(identifiers: batch)
            }
        } catch {
            logger.error("Spotlight index update failed", error: error, metadata: ["items": String(items.count + removed.count)])
        }
    }

    private func item(for reference: EntityReference) async throws -> SystemSearchItem? {
        switch reference.kind {
        case .task:
            return try await tasks.task(TaskItem.ID(reference.id)).flatMap { SystemSearchItems.item(for: $0, calendar: calendar) }
        case .note:
            return try await notes.note(Note.ID(reference.id)).flatMap(SystemSearchItems.item(for:))
        default:
            return nil
        }
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
