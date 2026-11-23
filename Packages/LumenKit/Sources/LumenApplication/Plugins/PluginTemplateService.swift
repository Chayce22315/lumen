import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenAutomation

/// Turns plugin workflow templates into the user's workflows. A template is added once: the
/// workflow it creates is remembered as owned by the plugin (removed when the plugin is
/// uninstalled), and adding it again opens that workflow.
public final class PluginTemplateService: Sendable {
    private let engine: AutomationEngine
    private let owned: PluginOwnedEntityStore
    private let extensions: ExtensionRegistry
    private let timeSource: any TimeSource

    init(engine: AutomationEngine, owned: PluginOwnedEntityStore, extensions: ExtensionRegistry, timeSource: any TimeSource) {
        self.engine = engine
        self.owned = owned
        self.extensions = extensions
        self.timeSource = timeSource
    }

    /// Templates offered by active plugins, by plugin then name.
    public func templates() -> [WorkflowTemplate] {
        extensions.contributions(to: LumenExtensionPoints.workflowTemplates).sorted { a, b in
            if a.pluginName != b.pluginName { return a.pluginName.foldedForMatching < b.pluginName.foldedForMatching }
            return a.name.foldedForMatching < b.name.foldedForMatching
        }
    }

    /// The workflow added from `template`, if it was added and still exists.
    public func addedWorkflow(for template: WorkflowTemplate) async throws -> Workflow? {
        guard let entity = try await owned.entity(pluginID: template.pluginID, contributionKey: template.contributionKey) else { return nil }
        if let workflow = try await engine.workflow(Workflow.ID(entity.entity.id)) { return workflow }
        // The user deleted it; the template can be added again.
        try await owned.forget(pluginID: template.pluginID, contributionKey: template.contributionKey)
        return nil
    }

    /// Adds the template as a workflow that starts switched off, so nothing runs until the user
    /// has looked at it and turned it on. Returns the existing workflow when already added.
    @discardableResult
    public func add(_ template: WorkflowTemplate, context: ActionContext = .user) async throws -> Workflow {
        if let existing = try await addedWorkflow(for: template) { return existing }
        let workflow = try await engine.create(
            WorkflowDraft(name: template.name, summary: template.summary, isEnabled: false, trigger: template.trigger, graph: template.graph),
            context: context
        )
        do {
            try await owned.record(PluginOwnedEntity(pluginID: template.pluginID, contributionKey: template.contributionKey, entity: workflow.reference, createdAt: timeSource.now()))
        } catch {
            // Without the record the workflow would outlive its plugin: undo it.
            try await engine.delete(workflow.id, context: context)
            throw error
        }
        return workflow
    }

    /// Runs the workflow added from `template`, adding it first if needed (a plugin command that
    /// "runs the weekly review" works before the user opened Automations).
    @discardableResult
    public func run(_ template: WorkflowTemplate, context: ActionContext = .user) async throws -> WorkflowRun {
        let workflow = try await add(template, context: context)
        return try await engine.run(workflow.id, context: context)
    }
}
