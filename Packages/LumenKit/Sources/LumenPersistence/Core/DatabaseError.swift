import Foundation
import LumenFoundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum DatabaseError: Error, Sendable, Equatable, CustomStringConvertible {
    /// SQLite returned an error code. `message` is SQLite's own description.
    case sqlite(code: Int32, message: String, sql: String?)
    case missingColumn(String)
    case typeMismatch(column: String, expected: String, actual: String)
    case migrationFailed(identifier: String, message: String)
    case duplicateMigration(String)
    case notFound(EntityReference)
    case closed

    public var description: String {
        switch self {
        case .sqlite(let code, let message, let sql):
            if let sql { return "SQLite error \(code): \(message) — in: \(sql)" }
            return "SQLite error \(code): \(message)"
        case .missingColumn(let column):
            return "Column '\(column)' is not present in the result row"
        case .typeMismatch(let column, let expected, let actual):
            return "Column '\(column)' holds \(actual), expected \(expected)"
        case .migrationFailed(let identifier, let message):
            return "Migration \(identifier) failed: \(message)"
        case .duplicateMigration(let identifier):
            return "Migration identifier \(identifier) is registered more than once"
        case .notFound(let reference):
            return "No record for \(reference.uri)"
        case .closed:
            return "The database connection is closed"
        }
    }

    /// True for SQLITE_CONSTRAINT and its extended codes.
    public var isConstraintViolation: Bool {
        if case .sqlite(let code, _, _) = self { return code & 0xFF == SQLITE_CONSTRAINT }
        return false
    }
}

extension DatabaseError: PresentableError {
    public var presentation: ErrorPresentation {
        switch self {
        case .notFound:
            return ErrorPresentation(title: "Not found", message: "This item no longer exists. It may have been deleted on another device.")
        default:
            return ErrorPresentation(
                title: "Storage problem",
                message: "Lumen couldn't read or save your data.",
                recoverySuggestion: "Try again. If it keeps happening, export diagnostics from Settings.",
                isRetryable: true
            )
        }
    }
}
