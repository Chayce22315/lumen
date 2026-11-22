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

/// The extension points Lumen offers to features and plugins.
public enum LumenExtensionPoints {
    public static let commands = ExtensionPoint<LumenCommand>("lumen.commands", requires: .contributeCommands)
    public static let searchSources = ExtensionPoint<any SearchableSource>("lumen.search.sources", requires: .contributeSearchResults)
    public static let assistantTools = ExtensionPoint<any AssistantTool>("lumen.assistant.tools", requires: .contributeAssistantTools)
    public static let automationActions = ExtensionPoint<any AutomationAction>("lumen.automation.actions", requires: .contributeAutomationActions)
}
