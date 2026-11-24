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
    private let discardHandedOverFile: @Sendable (URL) -> Void

    /// - Parameters:
    ///   - readFile: reads a package file (bounded); tests substitute it.
    ///   - discardHandedOverFile: removes the copy iOS made of a file another app handed over,
    ///     once it has been read; tests substitute it.
    public init(
        readFile: @escaping @Sendable (URL) throws -> Data = { try PluginPackageFile.read($0) },
        discardHandedOverFile: @escaping @Sendable (URL) -> Void = { PluginRequestInbox.removeInboxCopy($0) }
    ) {
        self.readFile = readFile
        self.discardHandedOverFile = discardHandedOverFile
    }

    /// Deletes `url` if it is the copy iOS placed in the app's `Documents/Inbox`; a file anywhere
    /// else (picked in Files, opened in place) is left alone.
    public nonisolated static func removeInboxCopy(_ url: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        PluginPackageFile.removeInboxCopy(url, documentsDirectory: documents)
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
            // The bytes are in memory now (or the file was unusable): iOS's copy isn't needed.
            // Only the file just read is removed, so a second file handed over at the same
            // moment is never deleted before it is read.
            discardHandedOverFile(url)
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

    /// Queues a request made inside the app (a catalog entry).
    public func receive(_ request: PluginInstallRequest) {
        pending = request
    }

    /// Queues the package file the user picked in Files.
    public func receiveFile(_ url: URL) {
        do {
            pending = .package(try readFile(url))
        } catch {
            pending = .unreadable(ErrorPresentation.from(error))
        }
    }
}
