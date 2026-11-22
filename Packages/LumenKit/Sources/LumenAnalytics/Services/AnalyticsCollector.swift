import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Records committed domain events into the device-local analytics tables.
///
/// The collector subscribes to every event on the bus. Each recorded event writes its raw row
/// and increments its `(day, name, actor)` daily count in one transaction, so the aggregate never
/// drifts from the log. Nothing is recorded while `AnalyticsSettings.collectionEnabled` is off,
/// events of analytics' own module are ignored, and recording the same event twice is a no-op.
///
/// Raw events are kept for `purge(rawEventsOlderThan:)`'s retention window; daily counts are
/// kept until the user erases analytics data, so long-term statistics survive retention.
public actor AnalyticsCollector {
    /// What happened to one event.
    public enum RecordOutcome: String, Sendable, Hashable, Codable {
        case recorded
        /// An event with the same id was recorded before.
        case duplicate
        /// Collection is turned off; the event was not stored.
        case collectionDisabled
        /// Analytics' own events are not recorded.
        case ignored
    }

    /// Running totals since the collector was created, for diagnostics.
    public struct Statistics: Sendable, Hashable, Codable {
        /// Events passed to `record(_:)`, from the subscription or directly.
        public var processed = 0
        public var recorded = 0
        public var duplicates = 0
        public var skippedWhileDisabled = 0
        public var ignored = 0
        /// Events that could not be stored (each failure is logged at `.error`).
        public var failed = 0

        public init() {}
    }

    private let database: Database
    private let events: EventBus
    private let settings: SettingsStore
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let logger: Logger
    private var consumer: Task<Void, Never>?
    private var totals = Statistics()

    public init(
        database: Database,
        events: EventBus,
        settings: SettingsStore,
        timeSource: any TimeSource,
        calendar: Calendar,
        logger: Logger
    ) {
        self.database = database
        self.events = events
        self.settings = settings
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
    }

    deinit {
        consumer?.cancel()
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { consumer != nil }

    /// Subscribes to all events. Calling `start()` while running does nothing.
    public func start() {
        guard consumer == nil else { return }
        let stream = events.events(matching: .all)
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.consume(event)
            }
        }
        logger.info("Analytics collection started")
    }

    /// Ends the subscription. Events published afterwards are not recorded.
    public func stop() {
        guard let consumer else { return }
        consumer.cancel()
        self.consumer = nil
        logger.info("Analytics collection stopped")
    }

    public func statistics() -> Statistics {
        totals
    }

    // MARK: - Recording

    /// Records one event, subject to the collection setting. This is the path every event from
    /// the subscription takes; calling it directly records synchronously with the caller, which
    /// tests and importers use to await the result deterministically.
    @discardableResult
    public func record(_ event: DomainEvent) async throws -> RecordOutcome {
        totals.processed += 1
        guard event.name.module != AnalyticsEvents.module else {
            totals.ignored += 1
            return .ignored
        }
        guard await settings.value(AnalyticsSettings.collectionEnabled) else {
            totals.skippedWhileDisabled += 1
            return .collectionDisabled
        }
        let record = AnalyticsEventRecord(event: event, calendar: calendar)
        let inserted: Bool
        do {
            inserted = try await database.write { db in
                guard try AnalyticsEventRepository.insert(record, in: db) else { return false }
                try DailyCountRepository.increment(day: record.day, name: record.name, actor: record.actor, in: db)
                return true
            }
        } catch {
            totals.failed += 1
            throw error
        }
        if inserted {
            totals.recorded += 1
            return .recorded
        }
        totals.duplicates += 1
        return .duplicate
    }

    private func consume(_ event: DomainEvent) async {
        do {
            try await record(event)
        } catch {
            // The subscription keeps running; the failure is counted in `statistics()` and logged.
            logger.error("Analytics event could not be recorded", error: error, metadata: ["event": event.name.rawValue])
        }
    }

    // MARK: - Retention

    /// Deletes raw events recorded more than `days` days before today. Daily counts are kept, so
    /// counts, series, streaks and reports stay complete; only hour-of-day statistics and the
    /// activity feed are limited to the retention window. Returns the number of events deleted.
    @discardableResult
    public func purge(rawEventsOlderThan days: Int = 180) async throws -> Int {
        let today = CalendarDate(timeSource.now(), calendar: calendar)
        let cutoff = today.adding(days: -max(0, days))
        let deleted = try await database.write { db in
            try AnalyticsEventRepository.deleteEvents(before: cutoff, in: db)
        }
        logger.info("Purged raw analytics events", metadata: ["deleted": String(deleted), "before": cutoff.description])
        return deleted
    }
}
