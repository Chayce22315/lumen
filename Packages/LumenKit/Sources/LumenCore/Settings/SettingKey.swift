import Foundation

/// A typed key into `SettingsStore`. Declare keys as static constants next to the feature that
/// owns them; the name is persisted and must stay stable.
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}
