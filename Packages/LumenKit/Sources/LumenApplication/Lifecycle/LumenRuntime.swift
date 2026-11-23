import Foundation
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenSearch
import LumenIntelligence
import LumenAutomation
import LumenKnowledge

/// Lifecycle of a running Lumen: activation of features, background engines and the work done
/// when the app enters the foreground or background.
public actor LumenRuntime {
    public let services: LumenServices
    private var started = false
    private var extensionWatcher: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var textBackfill: Task<Void, Never>?
    private var isBackfillingText = false
    private var contributedTools: Set<String> = []
    private var contributedActions: Set<AutomationActionID> = []
    private let logger: Logger
    /// How often schedules and delayed automation steps are checked while the app runs.
    public static let automationTickInterval: TimeInterval = 60

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
        await services.documentFiles.start()
        await services.automation.engine.start()
        await services.focus.coordinator.start()
        // Follows changes; a rebuild after a format change runs behind, at utility priority.
        await services.spotlight.start()
        do {
            _ = try await services.automation.engine.recoverInterruptedRuns()
        } catch {
            services.errors.report(error, context: "Recovering automations")
        }
        startScheduler()

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
        await applyWidgetActions()
        await services.focus.coordinator.reconcile()
        await services.widgets.refresh()
        // Reading files for text is slow and never needed for launch: it runs behind.
        textBackfill = Task(priority: .utility) { [weak self] in
            await self?.backfillDocumentText()
        }
        logger.info("Runtime started")
    }

    /// Extracts text for documents imported before their format could be read, once per
    /// extraction version. A run that stops early (cancelled, out of time) resumes next time.
    @discardableResult
    public func backfillDocumentText(shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }) async -> DocumentService.TextBackfillResult? {
        // One run at a time: a background launch starts one from `start()` while the refresh asks
        // for another.
        guard !isBackfillingText else { return nil }
        isBackfillingText = true
        defer { isBackfillingText = false }
        let version = await services.settings.value(LumenBootstrap.documentTextVersionKey)
        guard version < LumenBootstrap.currentDocumentTextVersion else { return nil }
        do {
            let result = try await services.knowledge.documents.extractMissingText(context: .system, shouldContinue: shouldContinue)
            if result.isComplete {
                try await services.settings.set(LumenBootstrap.currentDocumentTextVersion, for: LumenBootstrap.documentTextVersionKey)
            }
            return result
        } catch {
            services.errors.report(error, context: "Extracting document text")
            return nil
        }
    }

    /// Foreground: catch up on widget actions and time-based work.
    public func didBecomeActive() async {
        guard started else { return }
        await applyWidgetActions()
        await services.focus.coordinator.reconcile()
        await tickAutomations()
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
        scheduler?.cancel()
        scheduler = nil
        textBackfill?.cancel()
        await textBackfill?.value
        textBackfill = nil
        await services.focus.coordinator.stop()
        await services.spotlight.stop()
        await services.automation.engine.stop()
        await services.documentFiles.stop()
        await services.widgets.stop()
        await services.organization.reminders.stop()
        await services.analytics.collector.stop()
        await services.search.indexer.stop()
        await services.plugins.host.deactivateAll()
        services.events.finishAll()
        started = false
    }

    /// Runs due schedules and resumes delayed automation steps.
    public func tickAutomations() async {
        do {
            _ = try await services.automation.engine.tick()
        } catch {
            services.errors.report(error, context: "Running scheduled automations")
        }
    }

    private func startScheduler() {
        let interval = Self.automationTickInterval
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.tickAutomations()
            }
        }
    }

    /// Pushes current contributions into the engines that consume them. Contributions of
    /// plugins that were deactivated are removed.
    private func applyContributions() async {
        let extensions = services.plugins.extensions
        services.commands.reload(from: extensions)
        for source in extensions.contributions(to: LumenExtensionPoints.searchSources) {
            await services.search.indexer.register(source)
        }

        let tools = extensions.contributions(to: LumenExtensionPoints.assistantTools)
        let toolNames = Set(tools.map(\.definition.name))
        for name in contributedTools.subtracting(toolNames) {
            services.intelligence.tools.unregister(named: name)
        }
        for tool in tools where !contributedTools.contains(tool.definition.name) {
            do {
                try services.intelligence.tools.register(tool)
            } catch {
                services.errors.report(error, context: "Registering assistant tool \(tool.definition.name)")
            }
        }
        contributedTools = toolNames

        let actions = extensions.contributions(to: LumenExtensionPoints.automationActions)
        let actionIDs = Set(actions.map(\.descriptor.id))
        for id in contributedActions.subtracting(actionIDs) {
            _ = services.automation.catalog.unregister(id)
        }
        for action in actions where !contributedActions.contains(action.descriptor.id) {
            do {
                try services.automation.catalog.register(action)
            } catch {
                services.errors.report(error, context: "Registering automation action \(action.descriptor.id.rawValue)")
            }
        }
        contributedActions = actionIDs
    }
}
