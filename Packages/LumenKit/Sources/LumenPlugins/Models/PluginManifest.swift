import Foundation
import LumenFoundation

/// Semantic version `major.minor.patch`.
public struct PluginVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible, LosslessStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    public init?(_ description: String) {
        let parts = description.split(separator: ".", omittingEmptySubsequences: false)
        // Plain decimal digits only ("+1" or "１" are not versions), short enough to fit an Int.
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Rules for plugin identifiers, shared by built-in manifests and third-party packages.
public enum PluginIdentifier {
    /// Identifiers starting with this prefix belong to Lumen's built-in features.
    public static let reservedPrefix = "app.lumen."
    public static let maximumLength = 100

    /// Reverse-DNS with at least three segments of ASCII letters, digits and hyphens, each
    /// starting with a letter (`com.example.weekly-review`).
    public static func isValid(_ id: String) -> Bool {
        guard id.count <= maximumLength else { return false }
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { segment in
            guard let first = segment.first, first.isLetter, first.isASCII else { return false }
            return segment.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "-") && $0.isASCII }
        }
    }
}

/// What a plugin declares about itself before it runs.
public struct PluginManifest: Sendable, Hashable, Codable, Identifiable {
    /// Reverse-DNS identifier, e.g. `app.lumen.organization` or `com.example.pomodoro`.
    public let id: String
    public var name: String
    public var summary: String
    public var author: String
    public var version: PluginVersion
    public var capabilities: Set<PluginCapability>
    /// Declared capabilities the plugin can run without. The host activates a plugin once every
    /// other declared capability is granted; the plugin checks `PluginContext.has(_:)` before
    /// using an optional one. Third-party packages declare all of theirs optional, so the user
    /// can deny any capability and keep the rest of the plugin.
    public var optionalCapabilities: Set<PluginCapability>
    /// Lowest host API version the plugin works with.
    public var minimumHostVersion: PluginVersion

    public init(
        id: String,
        name: String,
        summary: String,
        author: String,
        version: PluginVersion,
        capabilities: Set<PluginCapability>,
        optionalCapabilities: Set<PluginCapability> = [],
        minimumHostVersion: PluginVersion = PluginVersion(major: 1, minor: 0, patch: 0)
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.author = author
        self.version = version
        self.capabilities = capabilities
        self.optionalCapabilities = optionalCapabilities.intersection(capabilities)
        self.minimumHostVersion = minimumHostVersion
    }

    /// Capabilities that must be granted before the plugin is activated.
    public var requiredCapabilities: Set<PluginCapability> {
        capabilities.subtracting(optionalCapabilities)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, author, version, capabilities, optionalCapabilities, minimumHostVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        self.version = try container.decode(PluginVersion.self, forKey: .version)
        self.capabilities = try container.decodeIfPresent(Set<PluginCapability>.self, forKey: .capabilities) ?? []
        self.optionalCapabilities = try container.decodeIfPresent(Set<PluginCapability>.self, forKey: .optionalCapabilities) ?? []
        self.minimumHostVersion = try container.decodeIfPresent(PluginVersion.self, forKey: .minimumHostVersion) ?? PluginVersion(major: 1, minor: 0, patch: 0)
    }

    /// Problems that prevent installation; empty when valid.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if !PluginIdentifier.isValid(id) {
            issues.append("Identifier must be reverse-DNS with at least three segments, like com.example.plugin.")
        }
        if name.nonBlank == nil { issues.append("Name is required.") }
        if name.count > 60 { issues.append("Name can be at most 60 characters.") }
        if summary.count > 300 { issues.append("Summary can be at most 300 characters.") }
        return issues
    }
}
