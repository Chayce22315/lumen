import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenAutomation
import LumenIntelligence

/// Connects third-party packages to the engines that execute them: it builds the plugin for an
/// installed package, checks workflow templates with the automation validator and links
/// against the app's destinations, and deletes what a plugin created when it is uninstalled.
struct PackagedPluginIntegration: PluginPackageIntegration {
    let automation: AutomationEngine
    let extensions: ExtensionRegistry
    let templates: PluginTemplateService
    let transport: any HTTPStreamingTransport
    let logger: Logger

    func makePlugin(for installed: InstalledPlugin) -> any LumenPlugin {
        PackagedPlugin(installed: installed, templates: templates, transport: transport, logger: logger)
    }

    func contentReport(for manifest: PluginPackageManifest) async -> PluginContentReport {
        var report = PluginContentReport()
        let actions = allowedActions(for: manifest)
        let knownEvents = automation.catalog.knownEventNames
        for (index, contribution) in manifest.contributions.workflows.enumerated() {
            let path = "manifest.contributions.workflows[\(index)]"
            let template: WorkflowTemplate
            do {
                template = try PluginWorkflowDecoding.template(contribution, index: index, manifest: manifest)
            } catch let failure as PluginWorkflowDecoding.Failure {
                report.errors.append(PluginPackageIssue(path: "\(path).\(failure.part)", message: "This isn't a valid automation \(failure.part)."))
                continue
            } catch {
                report.errors.append(PluginPackageIssue(path: path, message: "This automation template can't be read."))
                continue
            }
            let workflow = Workflow(name: template.name, summary: template.summary, isEnabled: false, trigger: template.trigger, graph: template.graph, createdAt: Date(timeIntervalSince1970: 0))
            for issue in WorkflowValidator.validate(workflow, actions: actions, knownEvents: knownEvents) {
                let entry = PluginPackageIssue(path: issue.nodeID.map { "\(path).graph.nodes[\(nodeIndex(of: $0, in: template.graph))]" } ?? path, message: "“\(template.name)”: \(issue.message)")
                if issue.severity == .error { report.errors.append(entry) } else { report.warnings.append(entry) }
            }
        }
        for (index, command) in manifest.contributions.commands.enumerated() {
            if case .openLink(let url) = command.action, DeepLink.destination(from: url) == nil {
                report.errors.append(PluginPackageIssue(path: "manifest.contributions.commands[\(index)].action.url", message: "This link doesn't open a place in Lumen."))
            }
        }
        return report
    }

    /// Templates may use Lumen's own automation steps and the package's own webhook steps, but
    /// not steps contributed by other third-party plugins (they may be missing or change).
    private func allowedActions(for manifest: PluginPackageManifest) -> [AutomationActionID: AutomationActionDescriptor] {
        var actions = automation.catalog.descriptorsByID
        for (owner, action) in extensions.contributionsWithOwners(to: LumenExtensionPoints.automationActions)
        where !owner.hasPrefix(PluginIdentifier.reservedPrefix) {
            actions[action.descriptor.id] = nil
        }
        for webhook in manifest.contributions.webhooks {
            let action = PluginWebhookAction(pluginID: manifest.id, pluginName: manifest.name, webhook: webhook, grantedHosts: [], transport: transport, logger: logger)
            actions[action.descriptor.id] = action.descriptor
        }
        return actions
    }

    private func nodeIndex(of id: WorkflowNode.ID, in graph: WorkflowGraph) -> Int {
        graph.index(of: id) ?? 0
    }

    func removeOwnedEntities(_ entities: [PluginOwnedEntity]) async throws {
        for owned in entities {
            guard owned.entity.kind == .workflow else {
                logger.warning("A plugin owned an entity of an unknown kind; it was left in place", metadata: ["plugin": owned.pluginID, "kind": owned.entity.kind.rawValue])
                continue
            }
            do {
                try await automation.delete(Workflow.ID(owned.entity.id), context: .user)
            } catch AutomationError.workflowNotFound {
                // Already deleted by the user: nothing left to remove.
            }
        }
    }
}
