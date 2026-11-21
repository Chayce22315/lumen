import Foundation

/// Task dependencies as a directed graph: an edge `a → b` means "a is blocked by b".
public struct DependencyGraph: Sendable {
    public typealias ID = TaskItem.ID

    public private(set) var blockers: [ID: Set<ID>]

    public init(blockers: [ID: Set<ID>] = [:]) {
        self.blockers = blockers
    }

    public init(tasks: [TaskItem]) {
        var blockers: [ID: Set<ID>] = [:]
        for task in tasks where !task.blockedBy.isEmpty {
            blockers[task.id] = Set(task.blockedBy)
        }
        self.blockers = blockers
    }

    /// True when making `task` depend on `blocker` would create a cycle (including self-dependency).
    public func wouldCreateCycle(task: ID, blockedBy blocker: ID) -> Bool {
        if task == blocker { return true }
        // A cycle appears if `task` is already reachable from `blocker` by following blockers.
        var stack = [blocker]
        var visited = Set<ID>()
        while let current = stack.popLast() {
            if current == task { return true }
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: blockers[current] ?? [])
        }
        return false
    }

    public mutating func add(task: ID, blockedBy blocker: ID) {
        blockers[task, default: []].insert(blocker)
    }

    /// Tasks that `blocker` blocks.
    public func dependents(of blocker: ID) -> Set<ID> {
        Set(blockers.compactMap { $0.value.contains(blocker) ? $0.key : nil })
    }

    /// Whether `task` has an open blocker. Blockers missing from `statuses` (deleted tasks) don't block.
    public func isBlocked(_ task: ID, statuses: [ID: TaskStatus]) -> Bool {
        (blockers[task] ?? []).contains { blocker in
            guard let status = statuses[blocker] else { return false }
            return !status.isClosed
        }
    }

    /// A topological order (blockers before dependents). Nodes on cycles, which validation
    /// prevents but synced data could contain, are appended at the end in identifier order.
    public func topologicalOrder(of ids: [ID]) -> [ID] {
        let members = Set(ids)
        var indegree: [ID: Int] = [:]
        var dependentsMap: [ID: [ID]] = [:]
        for id in ids {
            let relevant = (blockers[id] ?? []).filter { members.contains($0) }
            indegree[id] = relevant.count
            for blocker in relevant {
                dependentsMap[blocker, default: []].append(id)
            }
        }
        var ready = ids.filter { indegree[$0] == 0 }.sorted()
        var order: [ID] = []
        while !ready.isEmpty {
            let next = ready.removeFirst()
            order.append(next)
            for dependent in (dependentsMap[next] ?? []).sorted() {
                indegree[dependent, default: 0] -= 1
                if indegree[dependent] == 0 {
                    ready.append(dependent)
                    ready.sort()
                }
            }
        }
        if order.count < ids.count {
            let placed = Set(order)
            order.append(contentsOf: ids.filter { !placed.contains($0) }.sorted())
        }
        return order
    }
}
