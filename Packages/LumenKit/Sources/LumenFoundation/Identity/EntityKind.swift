import Foundation

/// The kind of a persisted entity, used wherever entities of different modules are handled
/// generically: search results, links and backlinks, sync change records, analytics and
/// automation triggers.
///
/// Modules declare their kinds as static constants in an extension, for example
/// `extension EntityKind { public static let task: EntityKind = "task" }`.
/// Raw values are persisted and synchronized, so they must never change once shipped.
public struct EntityKind: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: EntityKind, rhs: EntityKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension EntityKind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension EntityKind: CustomStringConvertible {
    public var description: String { rawValue }
}
