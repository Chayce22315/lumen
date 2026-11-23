import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenApplication

/// What the iPad sidebar shows beyond its fixed items: the Library's collections and the open
/// task counts of the smart lists.
@MainActor
@Observable
public final class SidebarViewModel {
    /// A collection as a sidebar item. Nested collections follow their parent.
    public struct CollectionItem: Sendable, Hashable, Identifiable {
        public let id: NoteCollection.ID
        public let name: String
        public let symbolName: String
        /// 0 for top-level collections.
        public let depth: Int
        /// The title with the collection's place, for VoiceOver ("Meetings, in Work").
        public let accessibilityLabel: String

        public var section: NavigationSection { .collection(id) }
    }

    public private(set) var collections: [CollectionItem] = []
    /// Counts for the smart-list badges, kept current by the Plan model.
    public let plan: PlanViewModel

    private let services: LumenServices
    private let router: Router
    private let observation = ObservationHandle()

    public init(services: LumenServices, router: Router) {
        self.services = services
        self.router = router
        self.plan = PlanViewModel(services: services)
    }

    /// Loads collections and counts and keeps both current.
    public func start() async {
        await plan.start()
        await loadCollections()
        services.events.observe(
            EventFilter(modules: ["knowledge", "sync"], entityKinds: [.collection]),
            into: observation
        ) { [weak self] in
            await self?.loadCollections()
        }
    }

    public func loadCollections() async {
        do {
            let tree = try await services.knowledge.collections.tree()
            collections = tree.flatMap { Self.items(for: $0, parents: []) }
            // A collection deleted here, on another device or by an automation leaves the sidebar.
            router.retainCollections(Set(collections.map(\.id)))
        } catch {
            services.errors.report(error, context: "Loading collections")
        }
    }

    /// The badge for a sidebar item: open tasks in Today, Overdue, Inbox and the other smart lists.
    public func badge(for section: NavigationSection) -> Int? {
        guard let list = section.smartList else { return nil }
        return plan.badge(for: list)
    }

    public func title(for section: NavigationSection) -> String {
        if case .collection(let id) = section, let item = collections.first(where: { $0.id == id }) {
            return item.name
        }
        return section.title
    }

    private static func items(for node: CollectionNode, parents: [String]) -> [CollectionItem] {
        let name = node.collection.name.isEmpty ? "Untitled collection" : node.collection.name
        let label = parents.last.map { "\(name), in \($0)" } ?? name
        let item = CollectionItem(
            id: node.collection.id,
            name: name,
            symbolName: node.collection.symbolName ?? NavigationSection.collection(node.collection.id).symbolName,
            depth: node.depth,
            accessibilityLabel: label
        )
        return [item] + node.children.flatMap { items(for: $0, parents: parents + [name]) }
    }
}
