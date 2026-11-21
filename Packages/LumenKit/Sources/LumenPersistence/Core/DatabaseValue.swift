import Foundation
import LumenFoundation

/// A value as SQLite stores it.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var typeName: String {
        switch self {
        case .null: return "NULL"
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        }
    }
}

/// A Swift type that maps to and from a single SQLite column.
///
/// `init?(sqlValue:)` returns `nil` on a type mismatch; `Row.get` turns that into a typed error.
public protocol DatabaseValueConvertible: Sendable {
    var sqlValue: SQLValue { get }
    init?(sqlValue: SQLValue)
}

extension DatabaseValueConvertible where Self: RawRepresentable, RawValue: DatabaseValueConvertible {
    public var sqlValue: SQLValue { rawValue.sqlValue }

    public init?(sqlValue: SQLValue) {
        guard let raw = RawValue(sqlValue: sqlValue) else { return nil }
        self.init(rawValue: raw)
    }
}

extension Optional: DatabaseValueConvertible where Wrapped: DatabaseValueConvertible {
    public var sqlValue: SQLValue {
        switch self {
        case .none: return .null
        case .some(let wrapped): return wrapped.sqlValue
        }
    }

    public init?(sqlValue: SQLValue) {
        if case .null = sqlValue {
            self = .none
            return
        }
        guard let wrapped = Wrapped(sqlValue: sqlValue) else { return nil }
        self = .some(wrapped)
    }
}

extension SQLValue: DatabaseValueConvertible {
    public var sqlValue: SQLValue { self }
    public init?(sqlValue: SQLValue) { self = sqlValue }
}

extension String: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .text(self) }

    public init?(sqlValue: SQLValue) {
        guard case .text(let value) = sqlValue else { return nil }
        self = value
    }
}

extension Int64: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .integer(self) }

    public init?(sqlValue: SQLValue) {
        switch sqlValue {
        case .integer(let value): self = value
        case .real(let value) where value.isFinite && value.rounded() == value
            && value >= -9_223_372_036_854_775_808 && value < 9_223_372_036_854_775_808:
            self = Int64(value)
        default: return nil
        }
    }
}

extension Int: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .integer(Int64(self)) }

    public init?(sqlValue: SQLValue) {
        guard let value = Int64(sqlValue: sqlValue), let converted = Int(exactly: value) else { return nil }
        self = converted
    }
}

extension Double: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .real(self) }

    public init?(sqlValue: SQLValue) {
        switch sqlValue {
        case .real(let value): self = value
        case .integer(let value): self = Double(value)
        default: return nil
        }
    }
}

extension Bool: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .integer(self ? 1 : 0) }

    public init?(sqlValue: SQLValue) {
        guard case .integer(let value) = sqlValue, value == 0 || value == 1 else { return nil }
        self = value == 1
    }
}

extension Data: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .blob(self) }

    public init?(sqlValue: SQLValue) {
        guard case .blob(let value) = sqlValue else { return nil }
        self = value
    }
}

/// Instants are stored as REAL seconds since 1970, which keeps them sortable and comparable in SQL.
extension Date: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .real(timeIntervalSince1970) }

    public init?(sqlValue: SQLValue) {
        guard let seconds = Double(sqlValue: sqlValue), seconds.isFinite else { return nil }
        self = Date(timeIntervalSince1970: seconds)
    }
}

extension UUID: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .text(uuidString) }

    public init?(sqlValue: SQLValue) {
        guard case .text(let text) = sqlValue, let uuid = UUID(uuidString: text) else { return nil }
        self = uuid
    }
}

extension Identifier: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .text(uuidString) }

    public init?(sqlValue: SQLValue) {
        guard let uuid = UUID(sqlValue: sqlValue) else { return nil }
        self.init(uuid)
    }
}

extension CalendarDate: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .text(description) }

    public init?(sqlValue: SQLValue) {
        guard case .text(let text) = sqlValue else { return nil }
        self.init(text)
    }
}

extension EntityKind: DatabaseValueConvertible {}

extension HybridTimestamp: DatabaseValueConvertible {
    public var sqlValue: SQLValue { .text(description) }

    public init?(sqlValue: SQLValue) {
        guard case .text(let text) = sqlValue else { return nil }
        self.init(text)
    }
}

/// Stores any `Codable` value as JSON text.
public struct JSONColumn<Value: Codable & Sendable>: DatabaseValueConvertible {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public var sqlValue: SQLValue {
        // Encoding plain model values cannot fail; an encoding failure is a programming error
        // surfaced as NULL, which the NOT NULL constraint on JSON columns then rejects loudly.
        guard let text = try? JSONCoding.encodeString(value) else { return .null }
        return .text(text)
    }

    public init?(sqlValue: SQLValue) {
        guard case .text(let text) = sqlValue,
              let value = try? JSONCoding.decode(Value.self, from: text) else { return nil }
        self.value = value
    }
}
