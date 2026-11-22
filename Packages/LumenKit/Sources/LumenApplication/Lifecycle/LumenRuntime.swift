import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenSearch

/// Lifecycle of a running Lumen: activation of features, background engines and the work done
/// when the app enters the foreground or background.
public actor LumenRuntime {
    public let services: LumenServices
    private var started = false
    private var extensionWatcher: Task<Void, Never>?
    private let logger: Logger

    public init(services: LumenServices) {
        self.services = services
        self.logger = services.logging.logger("runtime")
    }

    public var isStarted: Bool { started }

    /// Activates features and starts background engines. Idempotent. Individual failures are
    /// reported and do not prevent the rest of the app from starting.
    public func start() async {
        guard !started else { return }
        started = true
        let services = self.services

        await services.plugins.host.activateAll()
        await applyContributions()
        let changes = services.plugins.extensions.changes()
        extensionWatcher = Task { [weak self] in
            for await _ in changes {
                await self?.applyContributions()
            }
        }

        do {
            try await services.organization.calendars.ensureDefaultCalendar()
        } catch {
            services.errors.report(error, context: "Preparing the calendar")
        }

        await services.search.indexer.start()
        await services.analytics.collector.start()
        await services.organization.reminders.start()
        await services.widgets.start()

        let indexVersion = await services.settings.value(LumenBootstrap.searchIndexVersionKey)
        if indexVersion < LumenBootstrap.currentSearchIndexVersion {
            let count = await services.search.indexer.rebuildAll()
            do {
                try await services.settings.set(LumenBootstrap.currentSearchIndexVersion, for: LumenBootstrap.searchIndexVersionKey)
            } catch {
                services.errors.report(error, context: "Saving search index state")
            }
            logger.notice("Search index built", metadata: ["documents": String(count)])
        }

        await services.organization.reminders.refreshEventWindow()
        await services.widgets.refresh()
        logger.info("Runtime started")
    }

    /// Foreground: catch up on time-based work.
    public func didBecomeActive() async {
        guard started else { return }
        await services.organization.reminders.refreshEventWindow()
        _ = await services.sync.synchronizeIfDue()
        await services.widgets.refresh()
    }

    /// Background: leave widgets and the server up to date.
    public func didEnterBackground() async {
        guard started else { return }
        await services.widgets.refresh()
        _ = await services.sync.synchronizeIfDue()
    }

    public func shutdown() async {
        guard started else { return }
        extensionWatcher?.cancel()
        extensionWatcher = nil
        await services.widgets.stop()
        await services.organization.reminders.stop()
        await services.analytics.collector.stop()
        await services.search.indexer.stop()
        await services.plugins.host.deactivateAll()
        services.events.finishAll()
        started = false
    }

    /// Pushes current contributions into the engines that consume them.
    private func applyContributions() async {
        let extensions = services.plugins.extensions
        services.commands.reload(from: extensions)
        for source in extensions.contributions(to: LumenExtensionPoints.searchSources) {
            await services.search.indexer.register(source)
        }
    }
}
