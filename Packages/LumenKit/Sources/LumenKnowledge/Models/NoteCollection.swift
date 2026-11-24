import Foundation
import LumenFoundation

/// A folder that groups notes and documents. Collections nest through `parentID`.
public struct NoteCollection: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<NoteCollection>

    public let id: ID
    public var name: String
    /// `nil` for a top-level collection.
    public var parentID: ID?
    /// Position among siblings, ascending.
    public var sortOrder: Int
    /// SF Symbol name shown next to the collection, if the user chose one.
    public var symbolName: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        name: String,
        parentID: ID? = nil,
        sortOrder: Int = 0,
        symbolName: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.symbolName = symbolName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reference: EntityReference { EntityReference(kind: .collection, id: id) }
}

extension NoteCollection {
    enum CodingKeys: String, CodingKey {
        case id, name, parentID, sortOrder, symbolName, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            parentID: try container.decodeIfPresent(ID.self, forKey: .parentID),
            sortOrder: try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            symbolName: try container.decodeIfPresent(String.self, forKey: .symbolName),
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }
}

/// One collection with its nested children, as returned by `CollectionService.tree()`.
public struct CollectionNode: Sendable, Hashable, Identifiable {
    public var collection: NoteCollection
    public var children: [CollectionNode]
    /// 0 for top-level collections.
    public var depth: Int

    public init(collection: NoteCollection, children: [CollectionNode] = [], depth: Int = 0) {
        self.collection = collection
        self.children = children
        self.depth = depth
    }

    public var id: NoteCollection.ID { collection.id }

    /// This node and all of its descendants, depth first, in display order.
    public var flattened: [CollectionNode] {
        [self] + children.flatMap(\.flattened)
    }
}
