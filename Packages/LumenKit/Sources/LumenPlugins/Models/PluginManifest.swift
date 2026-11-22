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
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
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
    /// Lowest host API version the plugin works with.
    public var minimumHostVersion: PluginVersion

    public init(
        id: String,
        name: String,
        summary: String,
        author: String,
        version: PluginVersion,
        capabilities: Set<PluginCapability>,
        minimumHostVersion: PluginVersion = PluginVersion(major: 1, minor: 0, patch: 0)
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.author = author
        self.version = version
        self.capabilities = capabilities
        self.minimumHostVersion = minimumHostVersion
    }

    /// Problems that prevent installation; empty when valid.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        let validSegment: (Substring) -> Bool = { segment in
            guard let first = segment.first, first.isLetter, first.isASCII else { return false }
            return segment.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "-") && $0.isASCII }
        }
        if segments.count < 3 || !segments.allSatisfy(validSegment) {
            issues.append("Identifier must be reverse-DNS with at least three segments, like com.example.plugin.")
        }
        if name.nonBlank == nil { issues.append("Name is required.") }
        if name.count > 60 { issues.append("Name can be at most 60 characters.") }
        if summary.count > 300 { issues.append("Summary can be at most 300 characters.") }
        return issues
    }
}
