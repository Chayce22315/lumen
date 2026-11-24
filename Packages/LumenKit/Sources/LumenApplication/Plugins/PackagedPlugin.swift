import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenSearch
import LumenAutomation
import LumenIntelligence

/// An installed third-party package running as a plugin. It has no code of its own: activation
/// turns the package's data into contributions to Lumen's extension points, each only when the
/// user granted the capability it needs.
///
/// - Automation templates need `contributeWorkflowTemplates`.
/// - Commands need `contributeCommands`; a command that runs a workflow also needs the
///   templates capability, because the workflow comes from a template.
/// - Assistant shortcuts need `contributeAssistantPrompts`.
/// - Webhook steps need `contributeAutomationActions` and `network`, and only steps whose host
///   the user allowed are offered.
struct PackagedPlugin: LumenPlugin {
    let installed: InstalledPlugin
    let templates: PluginTemplateService
    let transport: any HTTPStreamingTransport
    let logger: Logger

    var manifest: PluginManifest { installed.manifest.pluginManifest }

    func activate(_ context: PluginContext) async throws {
        let package = installed.manifest
        let decoded = try PluginWorkflowDecoding.templates(of: package)

        if context.has(.contributeWorkflowTemplates) {
            for template in decoded.values.sorted(by: { $0.templateID < $1.templateID }) {
                try context.contribute(template, to: LumenExtensionPoints.workflowTemplates)
            }
        }
        if context.has(.contributeCommands) {
            for command in package.contributions.commands {
                guard let action = commandAction(command.action, templates: context.has(.contributeWorkflowTemplates) ? decoded : [:]) else { continue }
                let palette = PaletteCommand(
                    id: "plugin.\(package.id).\(command.id)",
                    title: command.title,
                    subtitle: command.subtitle ?? "",
                    symbolName: "puzzlepiece.extension",
                    keywords: command.keywords,
                    category: package.name
                )
                try context.contribute(LumenCommand(palette, action: action), to: LumenExtensionPoints.commands)
            }
        }
        if context.has(.contributeAssistantPrompts) {
            for prompt in package.contributions.prompts {
                try context.contribute(
                    PromptShortcut(pluginID: package.id, pluginName: package.name, shortcutID: prompt.id, title: prompt.title, prompt: prompt.prompt),
                    to: LumenExtensionPoints.assistantPrompts
                )
            }
        }
        if context.has(.contributeAutomationActions), context.has(.network) {
            for webhook in package.contributions.webhooks where installed.grantedHosts.contains(webhook.host) {
                let action = PluginWebhookAction(pluginID: package.id, pluginName: package.name, webhook: webhook, grantedHosts: installed.grantedHosts, transport: transport, logger: logger)
                try context.contribute(action, to: LumenExtensionPoints.automationActions)
            }
        }
    }

    /// What a command does; `nil` when it can't work with the current grants or Lumen version.
    private func commandAction(_ action: CommandContribution.Action, templates: [String: WorkflowTemplate]) -> CommandAction? {
        switch action {
        case .openLink(let url):
            return DeepLink.destination(from: url).map(CommandAction.navigate)
        case .runWorkflow(let templateID):
            guard let template = templates[templateID] else { return nil }
            let service = self.templates
            return .perform {
                let run = try await service.run(template)
                let message: String
                switch run.status {
                case .succeeded: message = "Ran “\(template.name)”."
                case .waiting, .running: message = "“\(template.name)” is running."
                case .failed, .cancelled, .interrupted: message = "“\(template.name)” didn't finish."
                }
                return CommandResult(message: message, destination: .entity(run.reference))
            }
        }
    }
}

/// Decodes a package's workflow templates into the automation engine's types.
enum PluginWorkflowDecoding {
    struct Failure: Error, Sendable {
        let index: Int
        let part: String
    }

    /// Templates keyed by their identifier within the package.
    static func templates(of manifest: PluginPackageManifest) throws -> [String: WorkflowTemplate] {
        var result: [String: WorkflowTemplate] = [:]
        for (index, contribution) in manifest.contributions.workflows.enumerated() {
            result[contribution.id] = try template(contribution, index: index, manifest: manifest)
        }
        return result
    }

    static func template(_ contribution: WorkflowTemplateContribution, index: Int, manifest: PluginPackageManifest) throws -> WorkflowTemplate {
        let trigger: TriggerDefinition
        let graph: WorkflowGraph
        do {
            trigger = try contribution.trigger.decode(as: TriggerDefinition.self)
        } catch {
            throw Failure(index: index, part: "trigger")
        }
        do {
            graph = try contribution.graph.decode(as: WorkflowGraph.self)
        } catch {
            throw Failure(index: index, part: "graph")
        }
        return WorkflowTemplate(
            pluginID: manifest.id,
            pluginName: manifest.name,
            templateID: contribution.id,
            name: contribution.name,
            summary: contribution.summary,
            trigger: trigger,
            graph: graph
        )
    }
}

extension PluginWorkflowDecoding.Failure: PresentableError {
    var presentation: ErrorPresentation {
        ErrorPresentation(title: "Plugin can't start", message: "One of its automation templates isn't valid.")
    }
}
