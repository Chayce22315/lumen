import Foundation
import LumenFoundation

/// A link written inside a note: `[[Title]]`, `[[Title|label]]` or an entity mention such as
/// `[[task:<UUID>]]`.
public struct EntityLink: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// `[[Title]]` — refers to a note by title.
        case wikiLink
        /// `[[kind:UUID]]` — refers to any entity by reference.
        case entityMention
    }

    /// The entity whose text contains the link.
    public var source: EntityReference
    /// Zero-based order of the link within its source.
    public var position: Int
    /// The linked entity; `nil` while a `[[Title]]` link matches no note.
    public var target: EntityReference?
    /// The title as written for `[[Title]]` links; the reference text (`kind:UUID`) for mentions.
    public var targetTitle: String
    /// The alias after `|`, if any.
    public var label: String?
    public var kind: Kind

    public init(
        source: EntityReference,
        position: Int,
        target: EntityReference?,
        targetTitle: String,
        label: String? = nil,
        kind: Kind
    ) {
        self.source = source
        self.position = position
        self.target = target
        self.targetTitle = targetTitle
        self.label = label
        self.kind = kind
    }

    public var id: String { "\(source.uri)#\(position)" }

    public var isResolved: Bool { target != nil }

    /// The text a link chip shows: the label when present, otherwise the title.
    public var displayText: String { label ?? targetTitle }
}

extension EntityLink {
    enum CodingKeys: String, CodingKey {
        case source, position, target, targetTitle, label, kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(EntityReference.self, forKey: .source),
            position: try container.decodeIfPresent(Int.self, forKey: .position) ?? 0,
            target: try container.decodeIfPresent(EntityReference.self, forKey: .target),
            targetTitle: try container.decodeIfPresent(String.self, forKey: .targetTitle) ?? "",
            label: try container.decodeIfPresent(String.self, forKey: .label),
            kind: try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .wikiLink
        )
    }
}
