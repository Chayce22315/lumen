import Foundation

/// A module-independent pointer to any persisted entity.
///
/// The textual form `kind:UUID` is used inside note bodies (`[[task:…]]` links), deep links and
/// sync payloads.
public struct EntityReference: Hashable, Sendable, Codable {
    public let kind: EntityKind
    public let id: UUID

    public init(kind: EntityKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public init<Owner>(kind: EntityKind, id: Identifier<Owner>) {
        self.init(kind: kind, id: id.rawValue)
    }

    /// Typed access to the identifier. The caller is responsible for checking `kind` first.
    public func identifier<Owner>(as _: Owner.Type = Owner.self) -> Identifier<Owner> {
        Identifier<Owner>(id)
    }

    /// `kind:UUID`, stable across releases.
    public var uri: String { "\(kind.rawValue):\(id.uuidString)" }

    public init?(uri: String) {
        guard let separator = uri.lastIndex(of: ":") else { return nil }
        let kindPart = uri[uri.startIndex..<separator]
        let idPart = uri[uri.index(after: separator)...]
        guard !kindPart.isEmpty, let uuid = UUID(uuidString: String(idPart)) else { return nil }
        self.init(kind: EntityKind(String(kindPart)), id: uuid)
    }
}

extension EntityReference: CustomStringConvertible {
    public var description: String { uri }
}
