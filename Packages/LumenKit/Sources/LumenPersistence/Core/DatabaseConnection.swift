import Foundation
import LumenFoundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Where the database lives.
public enum DatabaseLocation: Sendable, Equatable {
    /// A private in-memory database; used by tests and previews.
    case inMemory
    /// A file on disk. Parent directories are created if needed.
    case file(URL)
}

/// Where a change originated. Remote changes are applied by the sync engine and must not be
/// echoed back to the server, and automations must not trigger on their own writes.
public enum ChangeOrigin: String, Sendable, Codable, Hashable {
    case local
    case remote
}

/// A single SQLite connection.
///
/// Not thread-safe by design: it is only ever used inside the `Database` actor, which serializes
/// all access. Repositories receive it as a parameter of `Database.read`/`write` closures.
public final class DatabaseConnection {
    private var handle: OpaquePointer?
    private var statements: [String: Statement] = [:]
    private var transactionDepth = 0

    // Change tracking state, see `recordChange`.
    var clock: HybridLogicalClock
    let timeSource: any TimeSource
    public internal(set) var origin: ChangeOrigin = .local

    init(location: DatabaseLocation, replica: String = "pending", timeSource: any TimeSource) throws {
        self.timeSource = timeSource
        self.clock = HybridLogicalClock(replica: replica)
        let path: String
        switch location {
        case .inMemory:
            path = ":memory:"
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = url.path
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.sqlite(code: code, message: message, sql: nil)
        }
        self.handle = handle
        try configure(isFile: location != .inMemory)
    }

    deinit {
        close()
    }

    private func configure(isFile: Bool) throws {
        try executeScript("PRAGMA foreign_keys = ON;")
        try executeScript("PRAGMA busy_timeout = 5000;")
        // Deleted content (erased notes, analytics, conversations) is overwritten, not left in free pages.
        try executeScript("PRAGMA secure_delete = ON;")
        if isFile {
            // WAL lets the widget extension read while the app writes.
            _ = try query("PRAGMA journal_mode = WAL;")
            try executeScript("PRAGMA synchronous = NORMAL;")
        }
    }

    func close() {
        statements.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private func connection() throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.closed }
        return handle
    }

    private func statement(_ sql: String) throws -> Statement {
        if let cached = statements[sql] {
            cached.reset()
            return cached
        }
        let statement = try Statement(connection: try connection(), sql: sql)
        statements[sql] = statement
        return statement
    }

    // MARK: - Execution

    /// Executes a single statement that returns no rows.
    public func execute(_ sql: String, _ arguments: [any DatabaseValueConvertible] = []) throws {
        let statement = try statement(sql)
        defer { statement.reset() }
        try statement.bind(arguments)
        while try statement.step() {}
    }

    /// Executes one or more semicolon-separated statements without arguments (migrations, pragmas).
    public func executeScript(_ sql: String) throws {
        let handle = try connection()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if code != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw DatabaseError.sqlite(code: code, message: message, sql: sql)
        }
    }

    /// Runs a query and returns every row.
    public func query(_ sql: String, _ arguments: [any DatabaseValueConvertible] = []) throws -> [Row] {
        let statement = try statement(sql)
        defer { statement.reset() }
        try statement.bind(arguments)
        var rows: [Row] = []
        while try statement.step() {
            rows.append(statement.currentRow())
        }
        return rows
    }

    /// Runs a query and returns the first row, if any.
    public func queryFirst(_ sql: String, _ arguments: [any DatabaseValueConvertible] = []) throws -> Row? {
        let statement = try statement(sql)
        defer { statement.reset() }
        try statement.bind(arguments)
        return try statement.step() ? statement.currentRow() : nil
    }

    /// Runs a query and returns the first column of the first row; `nil` when there is no row or
    /// the value is NULL.
    public func scalar<T: DatabaseValueConvertible>(_ sql: String, _ arguments: [any DatabaseValueConvertible] = [], as _: T.Type = T.self) throws -> T? {
        guard let row = try queryFirst(sql, arguments), let first = row.values.first else { return nil }
        // An aggregate over no rows (`min()`, `max()`) yields NULL: that is "no value", not a type error.
        if case .null = first { return nil }
        guard let value = T(sqlValue: first) else {
            throw DatabaseError.typeMismatch(column: row.columnNames.first ?? "?", expected: String(describing: T.self), actual: first.typeName)
        }
        return value
    }

    /// Rows modified by the most recent statement.
    public var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    public var lastInsertedRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: - Transactions

    public var isInTransaction: Bool { transactionDepth > 0 }

    /// Runs `body` atomically. Nested calls become savepoints, so repositories can compose.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let depth = transactionDepth
        let savepoint = "lumen_sp_\(depth)"
        if depth == 0 {
            try executeScript("BEGIN IMMEDIATE TRANSACTION;")
        } else {
            try executeScript("SAVEPOINT \(savepoint);")
        }
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            if depth == 0 {
                try executeScript("COMMIT TRANSACTION;")
            } else {
                try executeScript("RELEASE SAVEPOINT \(savepoint);")
            }
            return result
        } catch {
            transactionDepth -= 1
            if depth == 0 {
                try? executeScript("ROLLBACK TRANSACTION;")
            } else {
                try? executeScript("ROLLBACK TO SAVEPOINT \(savepoint); RELEASE SAVEPOINT \(savepoint);")
            }
            throw error
        }
    }

    /// Runs `body` with a different change origin (used by the sync engine when applying remote changes).
    public func withOrigin<T>(_ origin: ChangeOrigin, _ body: () throws -> T) rethrows -> T {
        let previous = self.origin
        self.origin = origin
        defer { self.origin = previous }
        return try body()
    }

    /// True if a table exists; used by diagnostics and migrations.
    public func tableExists(_ name: String) throws -> Bool {
        let count: Int? = try scalar("SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?", [name])
        return (count ?? 0) > 0
    }

    /// Whether this SQLite build supports FTS5 (required by universal search).
    public func supportsFTS5() throws -> Bool {
        let enabled: Int? = try scalar("SELECT sqlite_compileoption_used('ENABLE_FTS5')")
        if enabled == 1 { return true }
        // Some builds load FTS5 without advertising the compile option; probe directly.
        do {
            try executeScript("CREATE VIRTUAL TABLE temp.lumen_fts5_probe USING fts5(x); DROP TABLE temp.lumen_fts5_probe;")
            return true
        } catch {
            return false
        }
    }
}
