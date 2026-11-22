import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenSync
import LumenPlugins
import LumenApplication

/// Settings › General, Sync, Plugins and Diagnostics.
@MainActor
@Observable
public final class SettingsViewModel {
    public struct Diagnostics: Sendable, Hashable {
        public let appVersion: String
        public let databaseBytes: Int64
        public let integrityProblems: [String]
        public let searchDocuments: Int
        public let recentLogs: [LogEntry]
        public let issues: [ReportedIssue]
    }

    public var displayName = ""
    public private(set) var syncStatus: SyncStatus?
    public private(set) var syncHistory: [SyncRun] = []
    public private(set) var conflicts: [SyncConflict] = []
    public private(set) var plugins: [PluginStatus] = []
    public private(set) var diagnostics: Diagnostics?
    public private(set) var isSyncing = false

    private let services: LumenServices

    public init(services: LumenServices) {
        self.services = services
    }

    public func load() async {
        displayName = await services.settings.value(HomeService.displayNameKey) ?? ""
        await loadSync()
        plugins = await services.plugins.host.statuses()
    }

    public func saveDisplayName() async {
        do {
            try await services.home.setDisplayName(displayName)
        } catch {
            services.errors.report(error, context: "Saving your name")
        }
    }

    // MARK: - Sync

    public func loadSync() async {
        syncStatus = await services.sync.status()
        do {
            syncHistory = try await services.sync.history(limit: 20)
            conflicts = try await services.sync.conflicts(includeReviewed: false)
        } catch {
            services.errors.report(error, context: "Loading sync status")
        }
    }

    public func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        _ = await services.sync.synchronize()
        await loadSync()
    }

    public func keep(_ conflict: SyncConflict) async {
        do {
            try await services.sync.markReviewed(conflict.id)
        } catch {
            services.errors.report(error, context: "Resolving a conflict")
        }
        await loadSync()
    }

    public func restoreOtherVersion(_ conflict: SyncConflict) async {
        do {
            try await services.sync.restoreLosingValues(of: conflict.id)
        } catch {
            services.errors.report(error, context: "Restoring a version")
        }
        await loadSync()
    }

    // MARK: - Plugins

    public func grant(_ capabilities: Set<PluginCapability>, to id: String) async {
        do {
            try await services.plugins.host.grant(capabilities, to: id)
            await services.plugins.host.activate(id)
        } catch {
            services.errors.report(error, context: "Granting plugin permissions")
        }
        plugins = await services.plugins.host.statuses()
    }

    public func revoke(_ capabilities: Set<PluginCapability>, from id: String) async {
        do {
            try await services.plugins.host.revoke(capabilities, from: id)
        } catch {
            services.errors.report(error, context: "Revoking plugin permissions")
        }
        plugins = await services.plugins.host.statuses()
    }

    public func setEnabled(_ enabled: Bool, plugin id: String) async {
        do {
            try await services.plugins.host.setEnabled(enabled, for: id)
        } catch {
            services.errors.report(error, context: "Changing a plugin")
        }
        plugins = await services.plugins.host.statuses()
    }

    // MARK: - Diagnostics

    public func loadDiagnostics() async {
        do {
            let database = services.database
            diagnostics = Diagnostics(
                appVersion: "\(services.configuration.appVersion) (\(services.configuration.buildNumber))",
                databaseBytes: try await database.approximateSize(),
                integrityProblems: try await database.integrityCheck(),
                searchDocuments: try await services.search.index.documentCount(),
                recentLogs: Array(services.recentLogs.snapshot().suffix(200).reversed()),
                issues: services.errors.recentIssues.reversed()
            )
        } catch {
            services.errors.report(error, context: "Running diagnostics")
        }
    }

    /// Rebuilds the search index from every source.
    public func rebuildSearchIndex() async -> Int {
        await services.search.indexer.rebuildAll()
    }

    /// Plain-text diagnostics report for support. Contains no user content.
    public func diagnosticsReport() -> String {
        guard let diagnostics else { return "" }
        var lines = [
            "Lumen \(diagnostics.appVersion)",
            "Database: \(diagnostics.databaseBytes) bytes, integrity \(diagnostics.integrityProblems.isEmpty ? "ok" : diagnostics.integrityProblems.joined(separator: "; "))",
            "Search documents: \(diagnostics.searchDocuments)",
            "",
            "Recent issues:",
        ]
        lines += diagnostics.issues.map { "- \($0.occurredAt) \($0.context): \($0.technicalDescription)" }
        lines += ["", "Recent log:"]
        lines += diagnostics.recentLogs.map { "\($0.date) [\($0.level.label)] \($0.category): \($0.message)" }
        return lines.joined(separator: "\n")
    }
}
