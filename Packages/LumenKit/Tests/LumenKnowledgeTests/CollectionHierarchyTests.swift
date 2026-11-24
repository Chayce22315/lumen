import Foundation
import Testing
import LumenKnowledge
import LumenTestSupport

@Suite("CollectionHierarchy")
struct CollectionHierarchyTests {
    let date = ManualTimeSource.referenceDate

    func collection(_ name: String, parent: NoteCollection? = nil, order: Int = 0) -> NoteCollection {
        NoteCollection(name: name, parentID: parent?.id, sortOrder: order, createdAt: date, updatedAt: date)
    }

    @Test("builds a nested tree in sort order with depths")
    func nestedTree() {
        let work = collection("Work", order: 1)
        let home = collection("Home", order: 0)
        let projects = collection("Projects", parent: work, order: 0)
        let archive = collection("archive", parent: work, order: 0)
        let lumen = collection("Lumen", parent: projects)
        let tree = CollectionHierarchy.tree(of: [lumen, archive, projects, home, work])

        #expect(tree.map(\.collection.name) == ["Home", "Work"])
        #expect(tree[1].children.map(\.collection.name) == ["archive", "Projects"])
        #expect(tree[1].children[1].children.map(\.collection.name) == ["Lumen"])
        #expect(tree[1].flattened.map(\.depth) == [0, 1, 1, 2])
        #expect(tree.flatMap(\.flattened).count == 5)
    }

    @Test("collections with a missing parent become top-level")
    func orphans() {
        let ghostParent = collection("Ghost")
        let orphan = collection("Orphan", parent: ghostParent)
        let tree = CollectionHierarchy.tree(of: [orphan])
        #expect(tree.map(\.collection.name) == ["Orphan"])
        #expect(tree[0].depth == 0)
    }

    @Test("cycles in stored data terminate and keep every collection")
    func cycles() {
        var a = collection("A")
        var b = collection("B", parent: a)
        a.parentID = b.id
        let selfParent = NoteCollection(id: .init(), name: "Self", createdAt: date, updatedAt: date)
        var looped = selfParent
        looped.parentID = looped.id
        b.sortOrder = 1
        let tree = CollectionHierarchy.tree(of: [a, b, looped])
        let names = tree.flatMap(\.flattened).map(\.collection.name)
        #expect(names.sorted() == ["A", "B", "Self"])
        #expect(Set(names).count == 3)
    }

    @Test("cycle detection for moves")
    func wouldCreateCycle() {
        let root = collection("Root")
        let child = collection("Child", parent: root)
        let grandchild = collection("Grandchild", parent: child)
        let other = collection("Other")
        let all = [root, child, grandchild, other]
        #expect(CollectionHierarchy.wouldCreateCycle(moving: root.id, under: root.id, in: all))
        #expect(CollectionHierarchy.wouldCreateCycle(moving: root.id, under: grandchild.id, in: all))
        #expect(CollectionHierarchy.wouldCreateCycle(moving: child.id, under: grandchild.id, in: all))
        #expect(!CollectionHierarchy.wouldCreateCycle(moving: grandchild.id, under: root.id, in: all))
        #expect(!CollectionHierarchy.wouldCreateCycle(moving: root.id, under: other.id, in: all))
        #expect(!CollectionHierarchy.wouldCreateCycle(moving: root.id, under: nil, in: all))
    }

    @Test("descendants and ancestors")
    func descendantsAndAncestors() {
        let root = collection("Root")
        let child = collection("Child", parent: root)
        let grandchild = collection("Grandchild", parent: child)
        let sibling = collection("Sibling", parent: root)
        let all = [root, child, grandchild, sibling]
        #expect(CollectionHierarchy.descendants(of: root.id, in: all) == [child.id, grandchild.id, sibling.id])
        #expect(CollectionHierarchy.descendants(of: grandchild.id, in: all).isEmpty)
        #expect(CollectionHierarchy.ancestors(of: grandchild.id, in: all).map(\.name) == ["Child", "Root"])
        #expect(CollectionHierarchy.ancestors(of: root.id, in: all).isEmpty)
    }
}
