import Foundation

/// What the application layer provides for third-party packages. The plugins engine owns the
/// format, trust, permissions and lifecycle; the meaning of contributions belongs to the engines
/// that execute them, which this engine never imports.
public protocol PluginPackageIntegration: Sendable {
    /// The plugin that contributes an installed package's contents through Lumen's extension
    /// points. It reads its granted hosts from `installed`, so a change of hosts restarts it.
    func makePlugin(for installed: InstalledPlugin) -> any LumenPlugin

    /// Checks contributions whose meaning belongs to other engines (workflow graphs against the
    /// automation validator, deep links against the app's destinations). Errors block install.
    func contentReport(for manifest: PluginPackageManifest) async -> PluginContentReport

    /// Deletes entities a plugin created on the user's request. Entities already gone count as
    /// removed.
    func removeOwnedEntities(_ entities: [PluginOwnedEntity]) async throws
}

/// Downloads package and catalog files.
public protocol PluginPackageDownloading: Sendable {
    /// The body of a successful `GET` of `url`. Throws when the response is not a success, the
    /// body exceeds `limit` bytes or nothing arrives within `timeout` seconds.
    func download(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data
}

/// For environments without network access (tests, previews).
public struct OfflinePluginDownloader: PluginPackageDownloading {
    public init() {}

    public func download(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        throw PluginPackageError.downloadFailed(host: url.host ?? "", reason: "Networking is disabled in this environment.")
    }
}
