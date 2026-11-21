import Foundation
import Synchronization
import LumenFoundation
import LumenPersistence
import LumenCore

/// The shared services most engine tests need: an in-memory database migrated with the given
/// schemas, an event bus, a manual clock, settings and a log capture.
public struct CoreTestEnvironment: Sendable {
    public let database: Database
    public let events: EventBus
    public let clock: ManualTimeSource
    public let calendar: Calendar
    public let logs: LogCapture
    public let logging: LoggingSystem
    public let settings: SettingsStore
    public let errors: ErrorReporter

    public static func make(schemas: [DatabaseSchema] = [], start: Date = ManualTimeSource.referenceDate) async throws -> CoreTestEnvironment {
        let clock = ManualTimeSource(start)
        let logs = LogCapture()
        let logging = logs.makeSystem()
        let database = try Database(location: .inMemory, timeSource: clock, logger: logging.logger("database"))
        try await database.migrate([SettingsStore.schema] + schemas)
        let events = EventBus()
        let settings = SettingsStore(database: database, events: events, timeSource: clock, logger: logging.logger("settings"))
        return CoreTestEnvironment(
            database: database,
            events: events,
            clock: clock,
            calendar: .testUTC,
            logs: logs,
            logging: logging,
            settings: settings,
            errors: ErrorReporter(logger: logging.logger("errors"), timeSource: clock)
        )
    }

    public func logger(_ category: String) -> Logger {
        logging.logger(category)
    }
}

/// Collects events from a bus so tests can assert on what was published.
public final class EventRecorder: Sendable {
    private let storage = Mutex<[DomainEvent]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(bus: EventBus, filter: EventFilter = .all) {
        let stream = bus.events(matching: filter)
        let consumer = Task { [weak self] in
            for await event in stream {
                self?.storage.withLock { $0.append(event) }
            }
        }
        task.withLock { $0 = consumer }
    }

    public var events: [DomainEvent] {
        storage.withLock { $0 }
    }

    public var names: [EventName] { events.map(\.name) }

    /// Waits (bounded) until at least `count` events arrived.
    public func waitForEvents(_ count: Int, timeout: TimeInterval = 2) async -> [DomainEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while events.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return events
    }

    public func stop() {
        task.withLock { $0?.cancel() }
    }

    deinit {
        task.withLock { $0?.cancel() }
    }
}
