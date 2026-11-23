import Foundation
import LumenPlugins
import LumenSearch
import LumenIntelligence
import LumenAutomation

/// What running a command does.
public enum CommandAction: Sendable {
    /// Navigates; the interface's router handles it.
    case navigate(AppDestination)
    /// Runs work; the result can confirm it (a toast) and/or lead somewhere.
    case perform(@Sendable () async throws -> CommandResult)
}

public struct CommandResult: Sendable, Hashable {
    public let message: String?
    public let destination: AppDestination?

    public init(message: String? = nil, destination: AppDestination? = nil) {
        self.message = message
        self.destination = destination
    }
}

/// A palette command together with what it does.
public struct LumenCommand: Sendable {
    public let command: PaletteCommand
    public let action: CommandAction

    public init(_ command: PaletteCommand, action: CommandAction) {
        self.command = command
        self.action = action
    }
}

/// A ready-made automation a plugin offers. Adding it creates an ordinary workflow (switched
/// off) that the plugin owns until it is uninstalled.
public struct WorkflowTemplate: Sendable, Hashable, Identifiable {
    public let pluginID: String
    public let pluginName: String
    public let templateID: String
    public let name: String
    public let summary: String
    public let trigger: TriggerDefinition
    public let graph: WorkflowGraph

    public init(pluginID: String, pluginName: String, templateID: String, name: String, summary: String, trigger: TriggerDefinition, graph: WorkflowGraph) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.templateID = templateID
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.graph = graph
    }

    public var id: String { "\(pluginID)/\(templateID)" }
    /// The key under which the workflow added from this template is remembered.
    public var contributionKey: String { "workflow:\(templateID)" }
}

/// A saved assistant prompt a plugin offers. It fills the composer of a new conversation; the
/// user sends it.
public struct PromptShortcut: Sendable, Hashable, Identifiable {
    public let pluginID: String
    public let pluginName: String
    public let shortcutID: String
    public let title: String
    public let prompt: String

    public init(pluginID: String, pluginName: String, shortcutID: String, title: String, prompt: String) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.shortcutID = shortcutID
        self.title = title
        self.prompt = prompt
    }

    public var id: String { "\(pluginID)/\(shortcutID)" }
}

/// The extension points Lumen offers to features and plugins.
public enum LumenExtensionPoints {
    public static let commands = ExtensionPoint<LumenCommand>("lumen.commands", requires: .contributeCommands)
    public static let searchSources = ExtensionPoint<any SearchableSource>("lumen.search.sources", requires: .contributeSearchResults)
    public static let assistantTools = ExtensionPoint<any AssistantTool>("lumen.assistant.tools", requires: .contributeAssistantTools)
    public static let automationActions = ExtensionPoint<any AutomationAction>("lumen.automation.actions", requires: .contributeAutomationActions)
    public static let workflowTemplates = ExtensionPoint<WorkflowTemplate>("lumen.automation.templates", requires: .contributeWorkflowTemplates)
    public static let assistantPrompts = ExtensionPoint<PromptShortcut>("lumen.assistant.prompts", requires: .contributeAssistantPrompts)
}
