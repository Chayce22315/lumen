import Foundation
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenKnowledge
import LumenTestSupport

/// All knowledge services over one in-memory database, manual clock and event bus.
struct KnowledgeHarness {
    let environment: CoreTestEnvironment
    let notes: NoteService
    let collections: CollectionService
    let documents: DocumentService
    let tags: TagService
    let storage: any DocumentStorage

    static func make(
        versionPolicy: VersionPolicy = VersionPolicy(),
        storage: (any DocumentStorage)? = nil
    ) async throws -> KnowledgeHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [KnowledgeSchema.schema])
        let storage = storage ?? InMemoryDocumentStorage()
        let logger = environment.logger("knowledge")
        return KnowledgeHarness(
            environment: environment,
            notes: NoteService(
                database: environment.database,
                events: environment.events,
                timeSource: environment.clock,
                logger: logger,
                versionPolicy: versionPolicy
            ),
            collections: CollectionService(database: environment.database, events: environment.events, timeSource: environment.clock, logger: logger),
            documents: DocumentService(database: environment.database, storage: storage, events: environment.events, timeSource: environment.clock, logger: logger),
            tags: TagService(database: environment.database, events: environment.events, timeSource: environment.clock, logger: logger),
            storage: storage
        )
    }

    var clock: ManualTimeSource { environment.clock }
    var database: Database { environment.database }

    func recorder() -> EventRecorder {
        EventRecorder(bus: environment.events, filter: EventFilter(modules: ["knowledge"]))
    }

    /// Every change record, oldest first.
    func changes() async throws -> [ChangeRecord] {
        try await database.read { db in try db.changes(after: 0, limit: 10_000) }
    }

    func changes(for entity: EntityReference) async throws -> [ChangeRecord] {
        try await database.read { db in try db.history(of: entity) }
    }
}

/// Wraps in-memory storage and counts writes and removals.
final class CountingStorage: DocumentStorage {
    let base = InMemoryDocumentStorage()
    private let counters = Mutex((writes: 0, removals: 0))
    private let failRemovals: Bool

    init(failRemovals: Bool = false) {
        self.failRemovals = failRemovals
    }

    struct RemovalFailed: Error {}

    var writeCount: Int { counters.withLock { $0.writes } }
    var removalCount: Int { counters.withLock { $0.removals } }

    func write(_ data: Data, key: String) async throws {
        counters.withLock { $0.writes += 1 }
        try await base.write(data, key: key)
    }

    func read(key: String) async throws -> Data {
        try await base.read(key: key)
    }

    func remove(key: String) async throws {
        counters.withLock { $0.removals += 1 }
        if failRemovals { throw RemovalFailed() }
        try await base.remove(key: key)
    }

    func exists(key: String) async -> Bool {
        await base.exists(key: key)
    }

    func url(for key: String) -> URL? { nil }
}

/// Deterministic pseudo-random numbers (SplitMix64) for property tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
