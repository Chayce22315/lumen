import Foundation
import LumenFoundation
import LumenCore

/// A module's searchable content, adapted by the application layer.
public protocol SearchableSource: Sendable {
    var kind: EntityKind { get }
    /// The current document for an entity, or `nil` when it no longer exists (it is then removed).
    func document(for id: UUID) async throws -> SearchDocument?
    /// Every document of this kind, for full rebuilds.
    func allDocuments() async throws -> [SearchDocument]
}

/// Keeps the index in step with the data by reacting to domain events. The index is a cache: a
/// failed update is logged and the entity is re-indexed on the next change or rebuild.
public actor SearchIndexer {
    private let index: SearchIndex
    private let events: EventBus
    private let logger: Logger
    private var sources: [EntityKind: any SearchableSource] = [:]
    private var consumer: Task<Void, Never>?
    private var inFlight = 0
    /// Events handled since `start()`, for deterministic waiting in tests.
    public private(set) var processedEventCount = 0

    public init(index: SearchIndex, events: EventBus, logger: Logger) {
        self.index = index
        self.events = events
        self.logger = logger
    }

    public func register(_ source: any SearchableSource) {
        sources[source.kind] = source
    }

    public var registeredKinds: Set<EntityKind> { Set(sources.keys) }

    /// Starts following the event bus. Idempotent.
    public func start() {
        guard consumer == nil else { return }
        let stream = events.events(matching: EventFilter(entityKinds: Set(sources.keys)))
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self, let entity = event.entity else { continue }
                await self.handle(entity)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
    }

    private func handle(_ entity: EntityReference) async {
        await reindex(entity)
        processedEventCount += 1
    }

    /// Waits (bounded) until at least `count` events have been handled.
    public func waitForProcessedEvents(_ count: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while processedEventCount < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Re-reads one entity from its source and updates or removes its document.
    public func reindex(_ reference: EntityReference) async {
        guard let source = sources[reference.kind] else { return }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            if let document = try await source.document(for: reference.id) {
                try await index.upsert(document)
            } else {
                try await index.remove(reference)
            }
        } catch {
            logger.error("Search index update failed", error: error, metadata: ["kind": reference.kind.rawValue])
        }
    }

    /// Rebuilds the documents of every registered kind. Returns the number of documents indexed.
    @discardableResult
    public func rebuildAll() async -> Int {
        var total = 0
        for (kind, source) in sources.sorted(by: { $0.key < $1.key }) {
            do {
                let documents = try await source.allDocuments()
                try await index.replaceAll(of: kind, with: documents)
                total += documents.count
            } catch {
                logger.error("Search rebuild failed", error: error, metadata: ["kind": kind.rawValue])
            }
        }
        logger.info("Search index rebuilt", metadata: ["documents": String(total)])
        return total
    }

    /// Waits until no update is running (bounded). Used by tests and before snapshots.
    public func waitUntilIdle(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
