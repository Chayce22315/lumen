import Foundation

/// A strongly typed identifier.
///
/// `Owner` is a phantom type: it is never stored, it only prevents identifiers of different
/// entities from being mixed up at compile time (`Identifier<TaskItem>` cannot be passed where
/// `Identifier<Note>` is expected).
public struct Identifier<Owner>: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }

    /// Re-types the identifier. Only use when two types genuinely share an identity space
    /// (for example a persisted record and its in-memory projection).
    public func retyped<Other>(as _: Other.Type = Other.self) -> Identifier<Other> {
        Identifier<Other>(rawValue)
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String { rawValue.uuidString }
}

extension Identifier: Comparable {
    public static func < (lhs: Identifier, rhs: Identifier) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}
