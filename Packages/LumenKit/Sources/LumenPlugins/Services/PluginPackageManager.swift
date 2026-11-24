import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Third-party plugin distribution: reviewing, installing, updating and uninstalling packages,
/// their permissions, downloads and catalogs. Lifecycle goes through `PluginHost` (activation
/// with rollback); what contributions mean is up to `PluginPackageIntegration`.
///
/// Logs and events carry plugin identifiers and versions only — never text from a package.
public actor PluginPackageManager {
    public static let packageInstalledEvent: EventName = "plugins.package.installed"
    public static let packageUpdatedEvent: EventName = "plugins.package.updated"
    public static let packageUninstalledEvent: EventName = "plugins.package.uninstalled"
    public static let catalogAddedEvent: EventName = "plugins.catalog.added"
    public static let catalogRefreshedEvent: EventName = "plugins.catalog.refreshed"
    public static let catalogRemovedEvent: EventName = "plugins.catalog.removed"
    /// How long a package or catalog download may stay silent before it is abandoned.
    public static let downloadTimeout: TimeInterval = 30

    let database: Database
    public nonisolated let host: PluginHost
    let events: EventBus
    let timeSource: any TimeSource
    let logger: Logger
    public nonisolated let reader: PluginPackageReader
    let integration: any PluginPackageIntegration
    let downloader: any PluginPackageDownloading
    /// Entities plugins created on request; removed with their plugin.
    public nonisolated let ownedEntities: PluginOwnedEntityStore

    public init(
        database: Database,
        host: PluginHost,
        events: EventBus,
        timeSource: any TimeSource,
        logger: Logger,
        verifier: any PluginSignatureVerifier,
        digest: @escaping @Sendable (Data) -> String,
        integration: any PluginPackageIntegration,
        downloader: any PluginPackageDownloading,
        limits: PluginPackageFormat.Limits = PluginPackageFormat.Limits()
    ) {
        self.database = database
        self.host = host
        self.events = events
        self.timeSource = timeSource
        self.logger = logger
        self.reader = PluginPackageReader(verifier: verifier, digest: digest, limits: limits)
        self.integration = integration
        self.downloader = downloader
        self.ownedEntities = PluginOwnedEntityStore(database: database)
    }

    // MARK: - Launch

    /// Registers every installed package with the host (before `activateAll`). Each stored file
    /// is decoded and its signature checked again; one that no longer reads is registered as a
    /// plugin that fails to start, so Settings shows why and it can be uninstalled.
    public func registerInstalled() async {
        let rows: [StoredPluginPackage]
        do {
            rows = try await database.read { db in try PluginPackageRepository.fetchAll(in: db) }
        } catch {
            logger.error("Installed plugins could not be read", error: error)
            return
        }
        for row in rows {
            let plugin: any LumenPlugin
            do {
                plugin = integration.makePlugin(for: try installedPlugin(from: row))
            } catch {
                logger.error("Installed plugin package could not be read", error: error, metadata: ["plugin": row.pluginID, "version": row.version])
                plugin = UnreadablePackagePlugin(row: row, error: error)
            }
            do {
                try await host.register(plugin, isBuiltIn: false)
            } catch {
                logger.error("Installed plugin could not be registered", error: error, metadata: ["plugin": row.pluginID])
            }
        }
    }

    // MARK: - Review

    /// Checks a package completely — format, limits, validation, signature, trust, compatibility,
    /// the application's content checks — and describes what installing it would do. Nothing is
    /// stored. Throws `PluginPackageError` for anything that prevents installing.
    public func review(_ data: Data, source: PluginSource) async throws -> PluginInstallReview {
        let verified = try reader.read(data)
        let manifest = verified.manifest
        guard manifest.minimumLumenVersion <= PluginHost.hostVersion else {
            throw PluginPackageError.incompatible(required: manifest.minimumLumenVersion, available: PluginHost.hostVersion)
        }
        let rows = try await database.read { db in try PluginPackageRepository.fetchAll(in: db) }
        let pinned = rows.map { row in (id: row.pluginID, key: row.publisherKey.flatMap { Data(base64Encoded: $0) }.map(reader.publisherKey)) }
        let trust = try PluginTrustEvaluator.evaluate(verified.signature, pluginID: manifest.id, installed: pinned)

        let current = rows.first { $0.pluginID == manifest.id }
        var installed: InstalledPlugin?
        if let current {
            do {
                installed = try installedPlugin(from: current)
            } catch {
                // An installed version that no longer reads can still be replaced; the review
                // then has nothing to compare against.
                logger.warning("Installed plugin package could not be read for comparison", metadata: ["plugin": manifest.id])
            }
            if let installed, manifest.version < installed.manifest.version {
                throw PluginPackageError.downgrade(pluginID: manifest.id, installed: installed.manifest.version, offered: manifest.version)
            }
        }

        let report = await integration.contentReport(for: manifest)
        guard report.errors.isEmpty else { throw PluginPackageError.invalid(report.errors) }

        var grants: Set<PluginCapability> = []
        if await host.isRegistered(manifest.id) {
            grants = try await host.grantedCapabilities(of: manifest.id)
        }
        logger.info("Plugin package reviewed", metadata: ["plugin": manifest.id, "version": manifest.version.description, "signed": String(verified.signature.isSigned)])
        return PluginInstallReview(
            verified: verified,
            source: source,
            trust: trust,
            installed: installed,
            replacedPackageSHA256: current?.sha256,
            installedGrants: grants,
            warnings: report.warnings
        )
    }

    // MARK: - Install and update

    /// Installs or updates the reviewed package with the user's choices and activates it. If the
    /// plugin fails to start, everything is put back as it was (the previous version, or
    /// nothing) and `activationFailed` is thrown.
    @discardableResult
    public func install(_ review: PluginInstallReview, choices: PluginInstallChoices) async throws -> PluginState {
        guard host.allowsThirdParty else { throw PluginPackageError.thirdPartyDisabled }
        if review.requiresUnsignedConfirmation, !choices.confirmsUnsigned { throw PluginPackageError.unsignedNotConfirmed }
        let manifest = review.manifest
        let id = manifest.id
        let previous = try await database.read { db in try PluginPackageRepository.fetch(id, in: db) }
        guard previous?.sha256 == review.replacedPackageSHA256 else { throw PluginPackageError.reviewOutdated(pluginID: id) }

        let now = timeSource.now()
        let hosts = choices.hosts.intersection(manifest.networkHosts)
        let capabilities = choices.capabilities.intersection(manifest.capabilities)
        let row = StoredPluginPackage(
            pluginID: id,
            version: manifest.version.description,
            data: review.package.data,
            sha256: review.package.sha256,
            publisherKey: review.trust.key?.base64,
            source: review.source,
            grantedHosts: hosts,
            installedAt: previous?.installedAt ?? now,
            updatedAt: now
        )
        let installed = InstalledPlugin(verified: review.verified, source: review.source, grantedHosts: hosts, installedAt: row.installedAt, updatedAt: now)
        let wasRegistered = await host.isRegistered(id)
        var previousGrants: Set<PluginCapability> = []
        if wasRegistered {
            previousGrants = try await host.grantedCapabilities(of: id)
        }

        try await database.write { db in try PluginPackageRepository.save(row, in: db) }
        let state: PluginState
        do {
            let plugin = integration.makePlugin(for: installed)
            if wasRegistered {
                try await host.replace(plugin)
            } else {
                try await host.register(plugin, isBuiltIn: false)
            }
            try await host.setGrants(capabilities, for: id)
            state = await host.activate(id)
            if case .failed(let message) = state {
                throw PluginPackageError.activationFailed(pluginID: id, message: message)
            }
        } catch {
            await restore(id, previous: previous, previousGrants: previousGrants, wasRegistered: wasRegistered)
            throw error
        }

        var attributes: [String: JSONValue] = ["plugin": .string(id), "version": .string(manifest.version.description), "signed": .bool(review.trust.key != nil)]
        if let from = previous?.version { attributes["previousVersion"] = .string(from) }
        events.publish(DomainEvent(name: previous == nil ? Self.packageInstalledEvent : Self.packageUpdatedEvent, attributes: attributes, actor: .user, occurredAt: now))
        logger.notice(previous == nil ? "Plugin installed" : "Plugin updated", metadata: ["plugin": id, "version": manifest.version.description])
        return state
    }

    /// Puts back what was there before a failed install: the previous package, its grants and
    /// registration — or removes the new plugin entirely.
    private func restore(_ id: String, previous: StoredPluginPackage?, previousGrants: Set<PluginCapability>, wasRegistered: Bool) async {
        do {
            if let previous {
                try await database.write { db in try PluginPackageRepository.save(previous, in: db) }
                let plugin: any LumenPlugin
                do {
                    plugin = integration.makePlugin(for: try installedPlugin(from: previous))
                } catch {
                    plugin = UnreadablePackagePlugin(row: previous, error: error)
                }
                if wasRegistered { try await host.replace(plugin) } else { try await host.register(plugin, isBuiltIn: false) }
                try await host.setGrants(previousGrants, for: id)
                await host.activate(id)
            } else {
                if await host.isRegistered(id) { try await host.uninstall(id) }
                try await database.write { db in try PluginPackageRepository.delete(id, in: db) }
            }
        } catch {
            logger.error("Restoring a plugin after a failed install failed", error: error, metadata: ["plugin": id])
        }
    }

    // MARK: - Uninstall

    /// Removes a plugin: its contributions (through the host), the entities it created on
    /// request, its grants, granted hosts and the stored package.
    public func uninstall(_ id: String) async throws {
        let row = try await database.read { db in try PluginPackageRepository.fetch(id, in: db) }
        let registered = await host.isRegistered(id)
        guard row != nil || registered else { throw PluginPackageError.notInstalled(id) }
        if registered {
            try await host.uninstall(id)
        }
        let owned = try await ownedEntities.entities(of: id)
        try await integration.removeOwnedEntities(owned)
        try await database.write { db in
            try PluginOwnedEntityRepository.deleteAll(pluginID: id, in: db)
            try PluginPackageRepository.delete(id, in: db)
        }
        events.publish(DomainEvent(
            name: Self.packageUninstalledEvent,
            attributes: ["plugin": .string(id), "removedEntities": .number(Double(owned.count))],
            actor: .user,
            occurredAt: timeSource.now()
        ))
        logger.notice("Plugin uninstalled", metadata: ["plugin": id, "removedEntities": String(owned.count)])
    }

    // MARK: - Permissions

    /// Sets exactly which capabilities and declared hosts an installed plugin has; it restarts
    /// with them (unless the user turned it off).
    public func updatePermissions(of id: String, capabilities: Set<PluginCapability>, hosts: Set<String>) async throws {
        guard let row = try await database.read({ db in try PluginPackageRepository.fetch(id, in: db) }) else {
            throw PluginPackageError.notInstalled(id)
        }
        let current = try installedPlugin(from: row)
        let allowedHosts = hosts.intersection(current.manifest.networkHosts)
        let now = timeSource.now()
        if allowedHosts != current.grantedHosts {
            try await database.write { db in try PluginPackageRepository.setGrantedHosts(allowedHosts, for: id, at: now, in: db) }
            // The plugin reads its hosts when created; a fresh instance picks up the change.
            let updated = InstalledPlugin(verified: current.verified, source: current.source, grantedHosts: allowedHosts, installedAt: current.installedAt, updatedAt: now)
            try await host.replace(integration.makePlugin(for: updated))
            try await host.setGrants(capabilities, for: id)
            await host.activate(id)
            events.publish(DomainEvent(name: PluginHost.permissionsChangedEvent, attributes: ["plugin": .string(id)], actor: .user, occurredAt: now))
        } else {
            try await host.setGrants(capabilities, for: id)
            await host.activate(id)
        }
        logger.info("Plugin permissions changed", metadata: ["plugin": id])
    }

    // MARK: - Queries

    /// Installed packages that read correctly, in installation order.
    public func installed() async throws -> [InstalledPlugin] {
        let rows = try await database.read { db in try PluginPackageRepository.fetchAll(in: db) }
        return rows.compactMap { row in
            do {
                return try installedPlugin(from: row)
            } catch {
                // Unreadable packages are listed by the host as failed plugins instead.
                return nil
            }
        }
    }

    public func installedPlugin(_ id: String) async throws -> InstalledPlugin? {
        guard let row = try await database.read({ db in try PluginPackageRepository.fetch(id, in: db) }) else { return nil }
        return try installedPlugin(from: row)
    }

    /// Installed versions by plugin identifier, including packages that no longer read.
    public func installedVersions() async throws -> [String: PluginVersion] {
        let rows = try await database.read { db in try PluginPackageRepository.fetchAll(in: db) }
        return Dictionary(rows.compactMap { row in PluginVersion(row.version).map { (row.pluginID, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Downloads

    /// Downloads a package from a `lumen://plugin/install` link's address and reviews it.
    public func reviewDownload(from url: URL) async throws -> PluginInstallReview {
        let data = try await download(url, limit: reader.decoder.limits.maximumPackageBytes)
        return try await review(data, source: .link(url))
    }

    func download(_ url: URL, limit: Int) async throws -> Data {
        guard PluginInstallLink.isAllowedDownload(url) else { throw PluginPackageError.insecureURL }
        logger.info("Downloading plugin file")
        return try await downloader.download(url, limit: limit, timeout: Self.downloadTimeout)
    }

    // MARK: - Private

    /// Decodes a stored package and checks that it is still what was installed: same identifier,
    /// signed by the pinned key (or unsigned when installed unsigned).
    func installedPlugin(from row: StoredPluginPackage) throws -> InstalledPlugin {
        let verified = try reader.read(row.data)
        guard verified.manifest.id == row.pluginID else {
            throw PluginPackageError.malformed(path: "manifest.id", reason: "The stored package doesn't match the installed plugin.")
        }
        guard verified.signature.key?.base64 == row.publisherKey else { throw PluginPackageError.signatureInvalid }
        return InstalledPlugin(verified: verified, source: row.source, grantedHosts: row.grantedHosts, installedAt: row.installedAt, updatedAt: row.updatedAt)
    }
}

/// Stands in for an installed package that can no longer be read (its signature no longer
/// verifies, or a newer Lumen wrote it): it fails to start with the reason, and can be
/// uninstalled from Settings.
struct UnreadablePackagePlugin: LumenPlugin {
    let manifest: PluginManifest
    let failure: PluginPackageError

    init(row: StoredPluginPackage, error: any Error) {
        self.manifest = PluginManifest(
            id: row.pluginID,
            name: row.pluginID,
            summary: "",
            author: "",
            version: PluginVersion(row.version) ?? PluginVersion(major: 0, minor: 0, patch: 0),
            capabilities: []
        )
        self.failure = error as? PluginPackageError ?? .malformed(path: "", reason: "The installed package can't be read.")
    }

    func activate(_ context: PluginContext) async throws {
        throw failure
    }
}
