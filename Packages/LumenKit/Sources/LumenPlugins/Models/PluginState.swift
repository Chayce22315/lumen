import Foundation
import LumenFoundation

public enum PluginState: Sendable, Hashable {
    /// Registered, not running.
    case inactive
    case active
    /// The user turned it off.
    case disabled
    /// Waiting for the user to grant these capabilities.
    case needsPermission(Set<PluginCapability>)
    /// Activation failed; contributions were rolled back.
    case failed(String)
    /// The plugin needs a newer host.
    case incompatible
    /// Third-party plugins are switched off in this build.
    case blocked

    public var isActive: Bool { self == .active }
}

public struct PluginStatus: Sendable, Hashable, Identifiable {
    public let manifest: PluginManifest
    public let isBuiltIn: Bool
    public let state: PluginState
    public let grantedCapabilities: Set<PluginCapability>

    public var id: String { manifest.id }
}

public enum PluginError: PresentableError, Equatable {
    case unknownPlugin(String)
    case invalidManifest([String])
    case duplicatePlugin(String)
    case permissionDenied(plugin: String, capability: PluginCapability)
    case undeclaredCapability(plugin: String, capability: PluginCapability)
    case serviceUnavailable(String)
    case builtInCannotBeRemoved(String)
    case activationTimedOut(String)

    public var presentation: ErrorPresentation {
        switch self {
        case .unknownPlugin:
            return ErrorPresentation(title: "Plugin not found", message: "That plugin isn't installed.")
        case .invalidManifest(let issues):
            return ErrorPresentation(title: "Invalid plugin", message: issues.joined(separator: " "))
        case .duplicatePlugin:
            return ErrorPresentation(title: "Already installed", message: "A plugin with this identifier is already installed.")
        case .permissionDenied(_, let capability):
            return ErrorPresentation(title: "Permission needed", message: "This plugin needs permission to \(capability.title.lowercased()).", recoverySuggestion: "Grant it in Settings › Plugins.")
        case .undeclaredCapability(_, let capability):
            return ErrorPresentation(title: "Not allowed", message: "The plugin tried to \(capability.title.lowercased()) without declaring it.")
        case .serviceUnavailable:
            return ErrorPresentation(title: "Unavailable", message: "This part of Lumen isn't available to plugins.")
        case .builtInCannotBeRemoved:
            return ErrorPresentation(title: "Built-in feature", message: "Built-in features can be turned off but not removed.")
        case .activationTimedOut:
            return ErrorPresentation(title: "Plugin didn't start", message: "The plugin took too long to start and was stopped.", isRetryable: true)
        }
    }
}
