import Foundation
import LumenFoundation

/// The single owner of Lumen's SQLite database.
///
/// All access is serialized by the actor. Work is passed in as synchronous closures that receive the
/// connection, so a closure can never suspend half-way through a transaction.
public actor Database {
    private let connection: DatabaseConnection
    private let logger: Logger
    private let timeSource: any TimeSource

    /// Stable identifier of this device's copy of the data.
    public nonisolated let replicaID: String

    public init(
        location: DatabaseLocation,
        timeSource: any TimeSource = SystemTimeSource(),
        logger: Logger = .disabled()
    ) throws {
        let connection = try DatabaseConnection(location: location, timeSource: timeSource)
        _ = try Migrator.migrate(connection, schemas: [PersistenceSchema.schema], now: timeSource.now())

        let replica: String
        if let stored: String = try connection.scalar("SELECT value FROM lumen_replica WHERE key = 'replica_id'") {
            replica = stored
        } else {
            // Short, URL- and HLC-safe replica id (no dashes, the HLC separator).
            replica = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            try connection.execute("INSERT INTO lumen_replica (key, value) VALUES ('replica_id', ?)", [replica])
        }
        let latest: HybridTimestamp? = try connection.scalar("SELECT timestamp FROM lumen_changes ORDER BY timestamp DESC LIMIT 1")
        connection.clock = HybridLogicalClock(replica: replica, latest: latest.map {
            HybridTimestamp(milliseconds: $0.milliseconds, counter: $0.counter, replica: replica)
        })

        self.connection = connection
        self.replicaID = replica
        self.logger = logger
        self.timeSource = timeSource
        logger.info("Database opened", metadata: ["location": location == .inMemory ? "memory" : "file"])
    }

    /// Opens a private in-memory database.
    public static func inMemory(timeSource: any TimeSource = SystemTimeSource()) throws -> Database {
        try Database(location: .inMemory, timeSource: timeSource)
    }

    /// Applies every pending migration of `schemas`, in order.
    @discardableResult
    public func migrate(_ schemas: [DatabaseSchema]) throws -> MigrationReport {
        let report = try Migrator.migrate(connection, schemas: schemas, now: timeSource.now())
        if !report.applied.isEmpty {
            logger.notice("Applied migrations", metadata: ["count": String(report.applied.count)])
        }
        return report
    }

    /// Read-only work. Do not write inside `read`; use `write` so changes are transactional.
    public func read<T: Sendable>(_ work: @Sendable (DatabaseConnection) throws -> T) throws -> T {
        try work(connection)
    }

    /// Transactional work. Everything inside commits together or not at all.
    @discardableResult
    public func write<T: Sendable>(origin: ChangeOrigin = .local, _ work: @Sendable (DatabaseConnection) throws -> T) throws -> T {
        try connection.withOrigin(origin) {
            try connection.transaction {
                try work(connection)
            }
        }
    }

    /// Size of the database file in bytes (page count × page size), for diagnostics.
    public func approximateSize() throws -> Int64 {
        let pages: Int64 = try connection.scalar("PRAGMA page_count") ?? 0
        let pageSize: Int64 = try connection.scalar("PRAGMA page_size") ?? 0
        return pages * pageSize
    }

    /// Runs SQLite's integrity check; returns the problems found (empty when healthy).
    public func integrityCheck() throws -> [String] {
        let rows = try connection.query("PRAGMA integrity_check")
        let messages = try rows.map { try $0.get("integrity_check", as: String.self) }
        return messages == ["ok"] ? [] : messages
    }
}
