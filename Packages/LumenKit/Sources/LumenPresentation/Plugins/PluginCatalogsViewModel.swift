import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenApplication

/// Plugin catalogs the user added: static JSON indexes at `https` addresses. Lumen ships none.
@MainActor
@Observable
public final class PluginCatalogsViewModel {
    public struct EntryRow: Sendable, Hashable, Identifiable {
        public enum Status: Sendable, Hashable {
            case available
            case installed
            case updateAvailable(from: PluginVersion)
            /// A newer version than the catalog lists is installed.
            case newerInstalled(PluginVersion)
        }

        public let entry: PluginCatalogEntry
        public let catalog: PluginCatalog
        public let status: Status

        public var id: String { "\(catalog.id.uuidString)/\(entry.id)" }

        public var actionTitle: String? {
            switch status {
            case .available: return "Review"
            case .updateAvailable: return "Update"
            case .installed, .newerInstalled: return nil
            }
        }

        public var statusText: String {
            switch status {
            case .available: return "Version \(entry.version)"
            case .installed: return "Installed · version \(entry.version)"
            case .updateAvailable(let from): return "Update from \(from) to \(entry.version)"
            case .newerInstalled(let installed): return "Version \(installed) installed"
            }
        }
    }

    public private(set) var catalogs: [PluginCatalog] = []
    public private(set) var installedVersions: [String: PluginVersion] = [:]
    public var newCatalogAddress = ""
    public private(set) var addFailure: ErrorPresentation?
    public private(set) var isWorking = false
    public private(set) var isLoaded = false

    private let services: LumenServices

    public init(services: LumenServices) {
        self.services = services
    }

    public var canAdd: Bool { !isWorking && newCatalogAddress.nonBlank != nil }

    public func load() async {
        do {
            catalogs = try await services.plugins.packages.catalogs()
            installedVersions = try await services.plugins.packages.installedVersions()
        } catch {
            services.errors.report(error, context: "Loading plugin catalogs")
        }
        isLoaded = true
    }

    public func rows(for catalog: PluginCatalog) -> [EntryRow] {
        catalog.entries.map { entry in
            let status: EntryRow.Status
            switch installedVersions[entry.id] {
            case nil: status = .available
            case .some(let version) where version == entry.version: status = .installed
            case .some(let version) where version < entry.version: status = .updateAvailable(from: version)
            case .some(let version): status = .newerInstalled(version)
            }
            return EntryRow(entry: entry, catalog: catalog, status: status)
        }
    }

    /// Adds the catalog at `newCatalogAddress`. Returns whether it was added.
    @discardableResult
    public func add() async -> Bool {
        guard let text = newCatalogAddress.nonBlank else { return false }
        addFailure = nil
        guard let url = URL(string: text), url.scheme != nil else {
            addFailure = ErrorPresentation(title: "Not an address", message: "Enter the catalog's full address, starting with https://.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await services.plugins.packages.addCatalog(url)
            newCatalogAddress = ""
            await load()
            return true
        } catch {
            // Shown next to the address field so it can be corrected.
            addFailure = ErrorPresentation.from(error)
            return false
        }
    }

    public func refresh(_ catalog: PluginCatalog) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await services.plugins.packages.refreshCatalog(catalog.id)
        } catch {
            services.errors.report(error, context: "Refreshing a plugin catalog")
        }
        await load()
    }

    public func remove(_ catalog: PluginCatalog) async {
        do {
            try await services.plugins.packages.removeCatalog(catalog.id)
        } catch {
            services.errors.report(error, context: "Removing a plugin catalog")
        }
        await load()
    }
}
