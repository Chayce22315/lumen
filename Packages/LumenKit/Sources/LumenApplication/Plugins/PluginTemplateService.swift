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
        let workflow: Workflow
        do {
            workflow = try await engine.create(
                WorkflowDraft(name: template.name, summary: template.summary, isEnabled: false, trigger: template.trigger, graph: template.graph),
                context: context
            )
        } catch AutomationError.invalidWorkflow(let issues) {
            // The engine's description quotes step titles, which come from the package.
            throw PluginTemplateError.notRunnable(pluginID: template.pluginID, issues: issues.errors.map(\.message))
        }
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

extension PluginServices {
    /// Whether this build allows third-party plugins (`FeatureFlag.thirdPartyPlugins`).
    public var allowsThirdParty: Bool { host.allowsThirdParty }

    /// Assistant shortcuts offered by active plugins, by plugin then title.
    public func promptShortcuts() -> [PromptShortcut] {
        extensions.contributions(to: LumenExtensionPoints.assistantPrompts).sorted { a, b in
            if a.pluginName != b.pluginName { return a.pluginName.foldedForMatching < b.pluginName.foldedForMatching }
            return a.title.foldedForMatching < b.title.foldedForMatching
        }
    }

    /// A package's automation templates in the engine's types, for previews. The review already
    /// refused packages whose templates don't decode, so none are dropped in practice.
    public func templates(in manifest: PluginPackageManifest) -> [WorkflowTemplate] {
        manifest.contributions.workflows.enumerated().compactMap { index, contribution in
            try? PluginWorkflowDecoding.template(contribution, index: index, manifest: manifest)
        }
    }

    /// The automation step a package's webhook becomes, as automations reference it.
    public static func webhookActionID(pluginID: String, webhookID: String) -> AutomationActionID {
        PluginWebhookAction.actionID(pluginID: pluginID, webhookID: webhookID)
    }
}

/// Why a plugin's template can't become a workflow right now, typically because one of its
/// steps belongs to a permission or address the user hasn't allowed. `description` (logs)
/// carries the plugin identifier and a count only.
public enum PluginTemplateError: PresentableError, Equatable, CustomStringConvertible {
    case notRunnable(pluginID: String, issues: [String])

    public var presentation: ErrorPresentation {
        switch self {
        case .notRunnable(_, let issues):
            return ErrorPresentation(
                title: "Template can't be added",
                message: issues.prefix(2).joined(separator: " "),
                recoverySuggestion: "If a step is missing, allow the plugin's permissions and internet addresses in Settings › Plugins."
            )
        }
    }

    public var description: String {
        switch self {
        case .notRunnable(let pluginID, let issues): return "notRunnable(\(pluginID), issues: \(issues.count))"
        }
    }
}
