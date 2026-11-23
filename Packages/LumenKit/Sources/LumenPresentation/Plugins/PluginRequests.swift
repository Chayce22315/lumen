import Foundation
import Observation
import LumenFoundation
import LumenPlugins

/// Something the user asked to install: a package file's contents, an install link's address
/// or a catalog entry. Each opens the same install review.
public enum PluginInstallRequest: Sendable, Hashable, Identifiable {
    /// A package read from Files, the share sheet or "Open in Lumen".
    case package(Data)
    /// A `lumen://plugin/install` link's `https` address.
    case download(URL)
    case catalogEntry(PluginCatalogEntry, PluginCatalog)
    /// A file that couldn't be read; the review explains why.
    case unreadable(ErrorPresentation)

    public var id: String {
        switch self {
        case .package(let data): return "package.\(data.count).\(data.hashValue)"
        case .download(let url): return "download.\(url.absoluteString)"
        case .catalogEntry(let entry, let catalog): return "catalog.\(catalog.id.uuidString).\(entry.id).\(entry.version)"
        case .unreadable(let error): return "unreadable.\(error.title)"
        }
    }
}

/// Holds the install request that arrived from outside the app (an opened file or an install
/// link) until Settings › Plugins shows its review.
@MainActor
@Observable
public final class PluginRequestInbox {
    public var pending: PluginInstallRequest?

    private let readFile: @Sendable (URL) throws -> Data

    /// - Parameter readFile: reads a package file (bounded); tests substitute it.
    public init(readFile: @escaping @Sendable (URL) throws -> Data = { try PluginPackageFile.read($0) }) {
        self.readFile = readFile
    }

    /// Takes a URL the app was asked to open. Returns `true` when it was a plugin package file or
    /// a plugin install link (now pending), `false` for anything else.
    public func accept(_ url: URL) -> Bool {
        if PluginInstallLink.isPackageFile(url) {
            do {
                pending = .package(try readFile(url))
            } catch {
                pending = .unreadable(ErrorPresentation.from(error))
            }
            return true
        }
        if url.scheme?.lowercased() == PluginInstallLink.scheme, url.host?.lowercased() == PluginInstallLink.host {
            if let package = PluginInstallLink.packageURL(from: url) {
                pending = .download(package)
            } else {
                pending = .unreadable(ErrorPresentation(
                    title: "Link not supported",
                    message: "Plugin links look like lumen://plugin/install?url=https://… and point to a .lumenplugin file."
                ))
            }
            return true
        }
        return false
    }

    /// Queues a package the user picked in Settings.
    public func receive(_ request: PluginInstallRequest) {
        pending = request
    }
}
