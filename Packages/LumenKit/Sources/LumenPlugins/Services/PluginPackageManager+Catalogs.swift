import Foundation
import LumenFoundation
import LumenCore

extension PluginPackageManager {
    /// Catalogs the user added, oldest first.
    public func catalogs() async throws -> [PluginCatalog] {
        try await database.read { db in try PluginCatalogRepository.fetchAll(in: db) }
    }

    /// Adds a catalog by its `https` address. It is fetched once first, so an address that isn't
    /// a catalog is refused instead of stored.
    @discardableResult
    public func addCatalog(_ url: URL) async throws -> PluginCatalog {
        guard PluginInstallLink.isAllowedDownload(url) else { throw PluginPackageError.insecureURL }
        if try await database.read({ db in try PluginCatalogRepository.exists(url: url, in: db) }) {
            throw PluginPackageError.catalogAlreadyAdded
        }
        let index = try await fetchCatalog(url)
        let now = timeSource.now()
        let catalog = PluginCatalog(url: url, name: index.name, entries: index.entries, addedAt: now, refreshedAt: now)
        try await database.write { db in try PluginCatalogRepository.save(catalog, in: db) }
        publishCatalogEvent(Self.catalogAddedEvent, catalog)
        logger.info("Plugin catalog added", metadata: ["catalog": catalog.id.uuidString, "entries": String(catalog.entries.count)])
        return catalog
    }

    /// Fetches a catalog's index again.
    @discardableResult
    public func refreshCatalog(_ id: PluginCatalog.ID) async throws -> PluginCatalog {
        guard var catalog = try await database.read({ db in try PluginCatalogRepository.fetch(id, in: db) }) else {
            throw PluginPackageError.unknownCatalog
        }
        let index = try await fetchCatalog(catalog.url)
        catalog.name = index.name
        catalog.entries = index.entries
        catalog.refreshedAt = timeSource.now()
        let refreshed = catalog
        try await database.write { db in try PluginCatalogRepository.save(refreshed, in: db) }
        publishCatalogEvent(Self.catalogRefreshedEvent, refreshed)
        return refreshed
    }

    /// Removes a catalog. Plugins installed from it stay installed.
    public func removeCatalog(_ id: PluginCatalog.ID) async throws {
        let catalog = try await database.read { db in try PluginCatalogRepository.fetch(id, in: db) }
        guard let catalog, try await database.write({ db in try PluginCatalogRepository.delete(id, in: db) }) else {
            throw PluginPackageError.unknownCatalog
        }
        publishCatalogEvent(Self.catalogRemovedEvent, catalog)
    }

    /// Downloads a catalog entry's package, checks it is the file the catalog lists (SHA-256,
    /// identifier and version) and reviews it like any other package.
    public func reviewCatalogEntry(_ entry: PluginCatalogEntry, from catalog: PluginCatalog) async throws -> PluginInstallReview {
        let data = try await download(entry.url, limit: reader.decoder.limits.maximumPackageBytes)
        let digest = reader.sha256(data)
        guard digest == entry.sha256 else {
            logger.warning("Catalog package digest mismatch", metadata: ["plugin": entry.id])
            throw PluginPackageError.digestMismatch(expected: entry.sha256, actual: digest)
        }
        let review = try await review(data, source: .catalog(catalogURL: catalog.url, packageURL: entry.url))
        guard review.manifest.id == entry.id, review.manifest.version == entry.version else {
            throw PluginPackageError.catalogMismatch(pluginID: entry.id)
        }
        return review
    }

    private func fetchCatalog(_ url: URL) async throws -> PluginCatalogParser.Index {
        let data = try await download(url, limit: PluginCatalogParser.maximumBytes)
        return try PluginCatalogParser.parse(data)
    }

    private func publishCatalogEvent(_ name: EventName, _ catalog: PluginCatalog) {
        events.publish(DomainEvent(
            name: name,
            attributes: ["catalog": .string(catalog.id.uuidString), "entries": .number(Double(catalog.entries.count))],
            actor: .user,
            occurredAt: timeSource.now()
        ))
    }
}
