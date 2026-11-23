import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenSearch
import LumenSync
import LumenPlugins
import LumenAnalytics
import LumenWidgetData
import LumenKnowledge
import LumenIntelligence
import LumenAutomation

/// Builds the object graph and brings Lumen up.
public enum LumenBootstrap {
    /// Settings key recording which search index format was last built, so the index is rebuilt
    /// after an update changes what is indexed.
    static let searchIndexVersionKey = SettingKey("search.indexVersion", default: 0)
    static let currentSearchIndexVersion = 1
    /// Bumped when document text extraction learns a format, so older documents get their text.
    public static let documentTextVersionKey = SettingKey("knowledge.documentTextVersion", default: 0)
    public static let currentDocumentTextVersion = 1

    /// Every schema, in dependency order.
    static var schemas: [DatabaseSchema] {
        [
            SettingsStore.schema,
            NotificationService.schema,
            OrganizationSchema.schema,
            KnowledgeSchema.schema,
            SearchIndex.schema,
            SyncEngine.schema,
            PluginHost.schema,
            AnalyticsService.schema,
            AssistantEngine.schema,
            AutomationEngine.schema,
        ]
    }

    public static func make(
        configuration: AppConfiguration,
        platform: PlatformServices,
        timeSource: any TimeSource = SystemTimeSource(),
        calendar: Calendar = .current
    ) async throws -> LumenServices {
        // Logging first, so every later step can report.
        let recentLogs = RingBufferLogSink(capacity: 2_000)
        var sinks: [any LogSink] = [recentLogs]
        sinks.append(contentsOf: platform.additionalLogSinks)
        let minimumLevel: LogLevel = configuration.isEnabled(.verboseLogging) || configuration.flavor == .debug ? .debug : .info
        let logging = LoggingSystem(sinks: sinks, minimumLevel: minimumLevel, timeSource: timeSource)
        let logger = logging.logger("bootstrap")

        let location: DatabaseLocation
        switch configuration.flavor {
        case .debug, .release: location = .file(configuration.databaseURL)
        case .test, .preview: location = .inMemory
        }
        let database = try Database(location: location, timeSource: timeSource, logger: logging.logger("database"))
        try await database.migrate(schemas)

        let events = EventBus()
        let settings = SettingsStore(database: database, events: events, timeSource: timeSource, logger: logging.logger("settings"))
        let errors = ErrorReporter(logger: logging.logger("errors"), timeSource: timeSource)
        let notifications = NotificationService(
            database: database, settings: settings, scheduler: platform.notificationScheduler, events: events,
            timeSource: timeSource, calendar: calendar, logger: logging.logger("notifications")
        )

        // Organization
        let tasks = TaskService(database: database, events: events, timeSource: timeSource, calendar: calendar, logger: logging.logger("tasks"))
        let projects = ProjectService(database: database, events: events, timeSource: timeSource, calendar: calendar, logger: logging.logger("projects"))
        let calendars = CalendarService(database: database, events: events, timeSource: timeSource, calendar: calendar, external: platform.externalCalendar, logger: logging.logger("calendar"))
        let agenda = AgendaService(tasks: tasks, calendars: calendars, timeSource: timeSource, calendar: calendar)
        let reminders = ReminderCoordinator(tasks: tasks, calendars: calendars, notifications: notifications, events: events, timeSource: timeSource, calendar: calendar, logger: logging.logger("reminders"))
        let organization = OrganizationServices(tasks: tasks, projects: projects, calendars: calendars, agenda: agenda, reminders: reminders)
        let focusSessions = FocusService(database: database, events: events, timeSource: timeSource, tasks: tasks, logger: logging.logger("focus"))
        let focus = FocusServices(
            service: focusSessions,
            coordinator: FocusCoordinator(
                focus: focusSessions, tasks: tasks, notifications: notifications, presenter: platform.focusActivities,
                events: events, timeSource: timeSource, logger: logging.logger("focus")
            )
        )

        // Knowledge
        let storage: any DocumentStorage
        if let provided = platform.documentStorage {
            storage = provided
        } else if location == .inMemory {
            storage = InMemoryDocumentStorage()
        } else {
            storage = FileSystemDocumentStorage(directory: configuration.documentsDirectory)
        }
        let notes = NoteService(database: database, events: events, timeSource: timeSource, logger: logging.logger("notes"))
        let collections = CollectionService(database: database, events: events, timeSource: timeSource, logger: logging.logger("collections"))
        // Files of documents added on other devices download on first read when the sync
        // transport also carries files.
        let blobs = BlobSynchronizer(
            database: database,
            transport: platform.syncTransport as? any BlobTransport,
            digest: { SHA256.hexDigest(of: $0) },
            timeSource: timeSource,
            logger: logging.logger("sync.files")
        )
        let documents = DocumentService(
            database: database, storage: SyncingDocumentStorage(local: storage, blobs: blobs),
            extractors: platform.documentTextExtractors,
            events: events, timeSource: timeSource, logger: logging.logger("documents")
        )
        let documentFiles = DocumentFileSync(documents: documents, local: storage, blobs: blobs, events: events, logger: logging.logger("sync.files"))
        let knowledge = KnowledgeServices(
            notes: notes,
            collections: collections,
            documents: documents,
            tags: TagService(database: database, events: events, timeSource: timeSource, logger: logging.logger("tags"))
        )

        // Automation
        let automationCatalog = AutomationCatalog(includeBuiltIns: true)
        automationCatalog.registerTriggers(from: BuiltInTriggerSource())
        let automationEngine = AutomationEngine(
            database: database, events: events, catalog: automationCatalog,
            timeSource: timeSource, calendar: calendar, logger: logging.logger("automation")
        )
        let automation = AutomationServices(engine: automationEngine, catalog: automationCatalog)

        // Search
        let index = SearchIndex(database: database, timeSource: timeSource)
        let indexer = SearchIndexer(index: index, events: events, logger: logging.logger("search"))
        let commandCenter = CommandCenter(registry: CommandRegistry())
        let search = SearchServices(index: index, indexer: indexer, service: SearchService(index: index, commands: commandCenter.registry, database: database, timeSource: timeSource))

        // Intelligence
        let transport: any HTTPStreamingTransport
        if let provided = platform.httpTransport {
            transport = provided
        } else if location == .inMemory {
            transport = OfflineTransport()
        } else {
            transport = URLSessionStreamingTransport()
        }
        let providers = ProviderRegistry([
            AnthropicProvider(transport: transport, secrets: platform.secrets, timeSource: timeSource, logger: logging.logger("provider.anthropic")),
            OpenAICompatibleProvider(configuration: .openAI, transport: transport, secrets: platform.secrets, timeSource: timeSource, logger: logging.logger("provider.openai")),
        ])
        let models = ModelCatalog(registry: providers, timeSource: timeSource, logger: logging.logger("models"))
        let tools = ToolRegistry()
        let memory = MemoryStore(database: database, events: events, settings: settings, timeSource: timeSource, logger: logging.logger("memory"))
        let approvals = ToolApprovalBroker()
        let assistant = AssistantEngine(
            database: database, events: events, settings: settings, secrets: platform.secrets,
            providers: providers, catalog: models, tools: tools, memory: memory,
            approvalHandler: approvals,
            contextProvider: WorkspaceContextProvider(agenda: agenda, projects: projects),
            attachmentResolver: KnowledgeAttachmentResolver(notes: notes, documents: documents),
            timeSource: timeSource, calendar: calendar, logger: logging.logger("assistant")
        )
        let conversations = ConversationService(database: database, events: events, timeSource: timeSource, logger: logging.logger("conversations"))
        let intelligence = IntelligenceServices(
            assistant: assistant, conversations: conversations, memory: memory, providers: providers, models: models,
            tools: tools, usage: UsageTracker(database: database, calendar: calendar, logger: logging.logger("usage")), approvals: approvals
        )

        // Analytics
        let signals = ProductivitySignals(
            completionEvents: [OrganizationEvent.taskCompleted],
            creationEvents: [OrganizationEvent.taskCreated],
            focusEvents: [OrganizationEvent.focusCompleted],
            moduleDisplayNames: ["organization": "Tasks", "knowledge": "Notes", "intelligence": "Assistant", "automation": "Automations"],
            unit: WorkUnit(singular: "task", plural: "tasks")
        )
        let analytics = AnalyticsServices(
            collector: AnalyticsCollector(
                database: database, events: events, settings: settings, timeSource: timeSource, calendar: calendar,
                logger: logging.logger("analytics"), measures: [FocusIntegration.minutesMeasure]
            ),
            service: AnalyticsService(database: database, settings: settings, events: events, timeSource: timeSource, calendar: calendar, logger: logging.logger("analytics")),
            signals: signals
        )

        // Sync
        let sync = SyncEngine(
            database: database,
            transport: platform.syncTransport,
            handlers: OrganizationIntegration.syncHandlers() + KnowledgeIntegration.syncHandlers() + IntelligenceIntegration.syncHandlers(),
            events: events,
            timeSource: timeSource,
            logger: logging.logger("sync")
        )

        // Plugins: built-in features go through the same host as third-party plugins.
        let extensions = ExtensionRegistry()
        let host = PluginHost(
            database: database,
            registry: extensions,
            services: BuiltInServiceProvider(),
            events: events,
            timeSource: timeSource,
            logging: logging,
            allowsThirdParty: configuration.isEnabled(.thirdPartyPlugins)
        )
        try await host.register(CoreFeature(), isBuiltIn: true)
        try await host.register(OrganizationFeature(tasks: tasks, projects: projects, calendars: calendars), isBuiltIn: true)
        try await host.register(KnowledgeFeature(notes: notes, collections: collections, documents: documents, timeSource: timeSource, calendar: calendar), isBuiltIn: true)
        let assistantTools: [any AssistantTool] = [
            SearchLumenTool(search: search.service),
            ListTasksTool(tasks: tasks),
            CreateTaskTool(tasks: tasks, projects: projects),
            CompleteTaskTool(tasks: tasks),
            AgendaTool(agenda: agenda),
            CreateNoteTool(notes: notes),
            ReadNoteTool(notes: notes),
            ListWorkflowsTool(automation: automationEngine),
            RunWorkflowTool(automation: automationEngine),
            StartFocusTool(focus: focusSessions, tasks: tasks),
            StopFocusTool(focus: focusSessions),
        ]
        try await host.register(IntelligenceFeature(tools: assistantTools, conversations: conversations), isBuiltIn: true)
        let automationActions: [any AutomationAction] = [
            CreateTaskAction(tasks: tasks, projects: projects),
            CompleteTaskAction(tasks: tasks),
            CreateNoteAction(notes: notes),
            AppendToNoteAction(notes: notes),
            SendNotificationAction(notifications: notifications),
            StartFocusAction(focus: focusSessions),
            StopFocusAction(focus: focusSessions),
        ]
        try await host.register(AutomationFeature(actions: automationActions, automation: automationEngine), isBuiltIn: true)
        for plugin in platform.plugins {
            do {
                try await host.register(plugin, isBuiltIn: false)
            } catch {
                errors.report(error, context: "Registering plugin \(plugin.manifest.id)")
            }
        }

        let home = HomeService(
            tasks: tasks, projects: projects, agenda: agenda, notes: notes, notifications: notifications, analytics: analytics,
            sync: sync, index: index, settings: settings, timeSource: timeSource, calendar: calendar
        )
        let widgets = WidgetSnapshotPublisher(
            store: WidgetSnapshotStore(url: configuration.widgetSnapshotURL),
            tasks: tasks, projects: projects, agenda: agenda, events: events,
            timeSource: timeSource, calendar: calendar, reload: platform.reloadWidgets, logger: logging.logger("widgets")
        )

        let services = LumenServices(
            configuration: configuration, timeSource: timeSource, calendar: calendar, logging: logging, recentLogs: recentLogs,
            database: database, events: events, settings: settings, secrets: platform.secrets, errors: errors,
            notifications: notifications, organization: organization, knowledge: knowledge,
            intelligence: intelligence, automation: automation, search: search, analytics: analytics, sync: sync,
            documentFiles: documentFiles,
            plugins: PluginServices(host: host, extensions: extensions), commands: commandCenter, home: home, widgets: widgets,
            focus: focus
        )
        logger.info("Services created", metadata: ["flavor": configuration.flavor.rawValue])
        return services
    }
}

/// Services offered to plugins. Built-in features receive their dependencies directly, so this
/// provider currently offers nothing; it is the seam where read-only facades for third-party
/// plugins are added.
struct BuiltInServiceProvider: PluginServiceProvider {
    func service(id: String, for pluginID: String) -> (any Sendable)? { nil }
}
