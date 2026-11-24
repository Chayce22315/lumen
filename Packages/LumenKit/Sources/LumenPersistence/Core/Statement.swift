import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A prepared statement. Owned by `DatabaseConnection`'s statement cache; never escapes it.
final class Statement {
    let handle: OpaquePointer
    let sql: String
    private let connection: OpaquePointer

    init(connection: OpaquePointer, sql: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errmsg(connection))
            if let handle { sqlite3_finalize(handle) }
            throw DatabaseError.sqlite(code: code, message: message, sql: sql)
        }
        self.handle = handle
        self.sql = sql
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ arguments: [any DatabaseValueConvertible]) throws {
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard expected == arguments.count else {
            throw DatabaseError.sqlite(
                code: SQLITE_RANGE,
                message: "Statement expects \(expected) arguments, got \(arguments.count)",
                sql: sql
            )
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch argument.sqlValue {
            case .null:
                code = sqlite3_bind_null(handle, index)
            case .integer(let value):
                code = sqlite3_bind_int64(handle, index, value)
            case .real(let value):
                code = sqlite3_bind_double(handle, index, value)
            case .text(let value):
                code = sqlite3_bind_text(handle, index, value, -1, Statement.transient)
            case .blob(let value):
                if value.isEmpty {
                    code = sqlite3_bind_zeroblob(handle, index, 0)
                } else {
                    code = value.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), Statement.transient)
                    }
                }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
    }

    /// Steps once. Returns `true` when a row is available.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(code)
        }
    }

    lazy var columnIndex: ColumnIndex = {
        let count = sqlite3_column_count(handle)
        let names = (0..<count).map { String(cString: sqlite3_column_name(handle, $0)) }
        return ColumnIndex(names: names)
    }()

    func currentRow() -> Row {
        let count = sqlite3_column_count(handle)
        var values: [SQLValue] = []
        values.reserveCapacity(Int(count))
        for column in 0..<count {
            values.append(columnValue(column))
        }
        return Row(columns: columnIndex, values: values)
    }

    private func columnValue(_ column: Int32) -> SQLValue {
        switch sqlite3_column_type(handle, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(handle, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(handle, column))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(handle, column) else { return .text("") }
            let length = Int(sqlite3_column_bytes(handle, column))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(handle, column))
            guard length > 0, let pointer = sqlite3_column_blob(handle, column) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: length))
        default:
            return .null
        }
    }

    private func error(_ code: Int32) -> DatabaseError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(connection)), sql: sql)
    }
}
