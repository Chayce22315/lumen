import Foundation
import LumenCore

/// Device-local assistant preferences. Names are persisted and must stay stable.
public enum AssistantSettings {
    /// The model new conversations (and conversations without their own selection) use.
    public static let defaultModel = SettingKey<ModelSelection?>("intelligence.defaultModel", default: nil)

    /// Global memory switch: when off, memories are neither sent to the model nor saved by it.
    public static let memoryEnabled = SettingKey("intelligence.memory.enabled", default: true)

    /// Ask before running tools that change the user's data. Read-only tools always run directly.
    public static let requireApprovalForMutatingTools = SettingKey("intelligence.tools.requireApprovalForMutatingTools", default: true)
}
