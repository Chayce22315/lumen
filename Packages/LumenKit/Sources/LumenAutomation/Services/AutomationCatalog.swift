import Foundation
import Synchronization
import LumenFoundation
import LumenCore

/// The registry of actions workflows can run and of events they can be triggered by.
///
/// Thread-safe: the application layer and plugins register while the engine reads.
public final class AutomationCatalog: Sendable {
    private struct Registry {
        var actions: [AutomationActionID: any AutomationAction] = [:]
        var triggers: [EventName: AutomationTriggerDescriptor] = [:]
    }

    private let registry = Mutex(Registry())

    /// - Parameter includeBuiltIns: registers the engine's own actions (`automation.formatText`,
    ///   `automation.setVariable`, `automation.stopRun`) and run-outcome triggers.
    public init(includeBuiltIns: Bool = true) {
        guard includeBuiltIns else { return }
        let actions = BuiltInActions.all
        let triggers = BuiltInAutomationTriggers().triggers
        registry.withLock { registry in
            for action in actions {
                registry.actions[action.descriptor.id] = action
            }
            for trigger in triggers {
                registry.triggers[trigger.eventName] = trigger
            }
        }
    }

    // MARK: - Actions

    /// Adds an action. Throws `AutomationError.duplicateAction` when the identifier is taken.
    public func register(_ action: any AutomationAction) throws {
        let id = action.descriptor.id
        let inserted = registry.withLock { registry -> Bool in
            guard registry.actions[id] == nil else { return false }
            registry.actions[id] = action
            return true
        }
        guard inserted else { throw AutomationError.duplicateAction(id) }
    }

    /// Removes an action. Workflows using it fail validation until it is registered again.
    @discardableResult
    public func unregister(_ id: AutomationActionID) -> Bool {
        registry.withLock { $0.actions.removeValue(forKey: id) != nil }
    }

    public func action(_ id: AutomationActionID) -> (any AutomationAction)? {
        registry.withLock { $0.actions[id] }
    }

    public func descriptor(_ id: AutomationActionID) -> AutomationActionDescriptor? {
        action(id)?.descriptor
    }

    /// Every action's descriptor, ordered by category, then title, then identifier.
    public var descriptors: [AutomationActionDescriptor] {
        let actions = registry.withLock { Array($0.actions.values) }
        return actions.map(\.descriptor).sorted { a, b in
            let categoryA = a.category.foldedForMatching, categoryB = b.category.foldedForMatching
            if categoryA != categoryB { return categoryA < categoryB }
            let titleA = a.title.foldedForMatching, titleB = b.title.foldedForMatching
            if titleA != titleB { return titleA < titleB }
            return a.id < b.id
        }
    }

    public var descriptorsByID: [AutomationActionID: AutomationActionDescriptor] {
        let actions = registry.withLock { Array($0.actions.values) }
        return Dictionary(actions.map { ($0.descriptor.id, $0.descriptor) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Triggers

    /// Adds or replaces the trigger descriptors of a source (the latest registration of an event wins).
    public func registerTriggers(from source: any AutomationTriggerSource) {
        let triggers = source.triggers
        registry.withLock { registry in
            for trigger in triggers {
                registry.triggers[trigger.eventName] = trigger
            }
        }
    }

    public func unregisterTriggers(_ names: [EventName]) {
        registry.withLock { registry in
            for name in names {
                registry.triggers[name] = nil
            }
        }
    }

    public func triggerDescriptor(for name: EventName) -> AutomationTriggerDescriptor? {
        registry.withLock { $0.triggers[name] }
    }

    /// Trigger descriptors ordered by category, then title.
    public var triggerDescriptors: [AutomationTriggerDescriptor] {
        registry.withLock { Array($0.triggers.values) }.sorted { a, b in
            let categoryA = a.category.foldedForMatching, categoryB = b.category.foldedForMatching
            if categoryA != categoryB { return categoryA < categoryB }
            let titleA = a.title.foldedForMatching, titleB = b.title.foldedForMatching
            if titleA != titleB { return titleA < titleB }
            return a.eventName < b.eventName
        }
    }

    public var knownEventNames: Set<EventName> {
        registry.withLock { Set($0.triggers.keys) }
    }
}
