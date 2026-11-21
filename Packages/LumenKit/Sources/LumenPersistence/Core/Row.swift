import Foundation

/// Immutable column-name lookup shared by every row of one result set.
final class ColumnIndex: Sendable {
    let names: [String]
    let positions: [String: Int]

    init(names: [String]) {
        self.names = names
        var positions: [String: Int] = [:]
        for (index, name) in names.enumerated() where positions[name] == nil {
            positions[name] = index
        }
        self.positions = positions
    }
}

/// One result row.
public struct Row: Sendable {
    let columns: ColumnIndex
    public let values: [SQLValue]

    init(columns: ColumnIndex, values: [SQLValue]) {
        self.columns = columns
        self.values = values
    }

    public var columnNames: [String] { columns.names }

    public func value(_ column: String) throws -> SQLValue {
        guard let position = columns.positions[column] else { throw DatabaseError.missingColumn(column) }
        return values[position]
    }

    /// Typed column access. Request an `Optional` type to accept `NULL`.
    public func get<T: DatabaseValueConvertible>(_ column: String, as _: T.Type = T.self) throws -> T {
        let raw = try value(column)
        guard let converted = T(sqlValue: raw) else {
            throw DatabaseError.typeMismatch(column: column, expected: String(describing: T.self), actual: raw.typeName)
        }
        return converted
    }

    /// Decodes a JSON text column.
    public func json<T: Codable & Sendable>(_ column: String, as _: T.Type = T.self) throws -> T {
        let column: JSONColumn<T> = try get(column)
        return column.value
    }

    /// Decodes a nullable JSON text column.
    public func optionalJSON<T: Codable & Sendable>(_ column: String, as _: T.Type = T.self) throws -> T? {
        let column: JSONColumn<T>? = try get(column)
        return column?.value
    }
}
