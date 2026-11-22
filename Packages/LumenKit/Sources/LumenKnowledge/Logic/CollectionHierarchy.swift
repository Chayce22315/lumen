import Foundation
import LumenFoundation

/// Pure operations on the collection hierarchy.
///
/// Stored data can be imperfect after synchronization (a parent that has not arrived yet, or a
/// cycle created by concurrent moves on two devices), so every function here terminates and treats
/// unknown parents as the root.
public enum CollectionHierarchy {
    /// Display order among siblings: `sortOrder`, then folded name, then identifier.
    public static func areInDisplayOrder(_ lhs: NoteCollection, _ rhs: NoteCollection) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        let lhsName = lhs.name.foldedForMatching, rhsName = rhs.name.foldedForMatching
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.id < rhs.id
    }

    /// The nested tree. Collections whose parent is missing become top-level; collections caught
    /// in a parent cycle are attached at the top level, starting from the first one in display order.
    public static func tree(of collections: [NoteCollection]) -> [CollectionNode] {
        let known = Set(collections.map(\.id))
        var childrenByParent: [NoteCollection.ID?: [NoteCollection]] = [:]
        for collection in collections {
            let parent = collection.parentID.flatMap { known.contains($0) && $0 != collection.id ? $0 : nil }
            childrenByParent[parent, default: []].append(collection)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort(by: areInDisplayOrder)
        }

        var visited = Set<NoteCollection.ID>()
        func build(_ collection: NoteCollection, depth: Int) -> CollectionNode {
            visited.insert(collection.id)
            var node = CollectionNode(collection: collection, depth: depth)
            for child in childrenByParent[collection.id] ?? [] where !visited.contains(child.id) {
                node.children.append(build(child, depth: depth + 1))
            }
            return node
        }

        var roots: [CollectionNode] = []
        let rootKey: NoteCollection.ID? = nil
        for root in childrenByParent[rootKey] ?? [] {
            roots.append(build(root, depth: 0))
        }
        // Anything not reached from a root sits on a cycle (or under one).
        let unreached = collections.filter { !visited.contains($0.id) }.sorted(by: areInDisplayOrder)
        for collection in unreached where !visited.contains(collection.id) {
            roots.append(build(collection, depth: 0))
        }
        return roots
    }

    /// Every collection below `id`, at any depth.
    public static func descendants(of id: NoteCollection.ID, in collections: [NoteCollection]) -> Set<NoteCollection.ID> {
        var childrenByParent: [NoteCollection.ID: [NoteCollection.ID]] = [:]
        for collection in collections {
            if let parent = collection.parentID {
                childrenByParent[parent, default: []].append(collection.id)
            }
        }
        var result = Set<NoteCollection.ID>()
        var pending = childrenByParent[id] ?? []
        while let next = pending.popLast() {
            guard next != id, result.insert(next).inserted else { continue }
            pending.append(contentsOf: childrenByParent[next] ?? [])
        }
        return result
    }

    /// Whether making `parentID` the parent of `id` would put `id` inside itself.
    public static func wouldCreateCycle(moving id: NoteCollection.ID, under parentID: NoteCollection.ID?, in collections: [NoteCollection]) -> Bool {
        guard let parentID else { return false }
        if parentID == id { return true }
        let parents = Dictionary(collections.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        var cursor: NoteCollection.ID? = parentID
        var seen = Set<NoteCollection.ID>()
        while let current = cursor, seen.insert(current).inserted {
            if current == id { return true }
            cursor = parents[current] ?? nil
        }
        return false
    }

    /// Ancestors of `id` from its parent up to the top level (breadcrumbs, nearest first).
    public static func ancestors(of id: NoteCollection.ID, in collections: [NoteCollection]) -> [NoteCollection] {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [NoteCollection] = []
        var seen: Set<NoteCollection.ID> = [id]
        var cursor = byID[id]?.parentID
        while let current = cursor, seen.insert(current).inserted, let collection = byID[current] {
            result.append(collection)
            cursor = collection.parentID
        }
        return result
    }
}
