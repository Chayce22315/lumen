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
import LumenKnowledge
import LumenIntelligence
import LumenAutomation

public struct OrganizationServices: Sendable {
    public let tasks: TaskService
    public let projects: ProjectService
    public let calendars: CalendarService
    public let agenda: AgendaService
    public let reminders: ReminderCoordinator
}

public struct KnowledgeServices: Sendable {
    public let notes: NoteService
    public let collections: CollectionService
    public let documents: DocumentService
    public let tags: TagService
}

public struct IntelligenceServices: Sendable {
    public let assistant: AssistantEngine
    public let conversations: ConversationService
    public let memory: MemoryStore
    public let providers: ProviderRegistry
    public let models: ModelCatalog
    public let tools: ToolRegistry
    public let usage: UsageTracker
    /// Where mutating assistant tools wait for the user's go-ahead.
    public let approvals: ToolApprovalBroker
}

public struct AutomationServices: Sendable {
    public let engine: AutomationEngine
    public let catalog: AutomationCatalog
}

public struct SearchServices: Sendable {
    public let index: SearchIndex
    public let indexer: SearchIndexer
    public let service: SearchService
}

public struct AnalyticsServices: Sendable {
    public let collector: AnalyticsCollector
    public let service: AnalyticsService
    /// Which events count as work created and completed, for insights and streaks.
    public let signals: ProductivitySignals
}

public struct PluginServices: Sendable {
    public let host: PluginHost
    public let extensions: ExtensionRegistry
}

/// The fully wired object graph. Created once by `LumenBootstrap` and shared by the interface,
/// App Intents and background work.
public final class LumenServices: Sendable {
    public let configuration: AppConfiguration
    public let timeSource: any TimeSource
    public let calendar: Calendar
    public let logging: LoggingSystem
    /// Recent log entries for the diagnostics screen.
    public let recentLogs: RingBufferLogSink
    public let database: Database
    public let events: EventBus
    public let settings: SettingsStore
    public let secrets: any SecretStore
    public let errors: ErrorReporter
    public let notifications: NotificationService
    public let organization: OrganizationServices
    public let knowledge: KnowledgeServices
    public let intelligence: IntelligenceServices
    public let automation: AutomationServices
    public let search: SearchServices
    public let analytics: AnalyticsServices
    public let sync: SyncEngine
    /// Uploads document files for other devices; downloads happen when a document is read.
    public let documentFiles: DocumentFileSync
    public let plugins: PluginServices
    public let commands: CommandCenter
    public let home: HomeService
    public let widgets: WidgetSnapshotPublisher
    public let focus: FocusServices

    init(
        configuration: AppConfiguration,
        timeSource: any TimeSource,
        calendar: Calendar,
        logging: LoggingSystem,
        recentLogs: RingBufferLogSink,
        database: Database,
        events: EventBus,
        settings: SettingsStore,
        secrets: any SecretStore,
        errors: ErrorReporter,
        notifications: NotificationService,
        organization: OrganizationServices,
        knowledge: KnowledgeServices,
        intelligence: IntelligenceServices,
        automation: AutomationServices,
        search: SearchServices,
        analytics: AnalyticsServices,
        sync: SyncEngine,
        documentFiles: DocumentFileSync,
        plugins: PluginServices,
        commands: CommandCenter,
        home: HomeService,
        widgets: WidgetSnapshotPublisher,
        focus: FocusServices
    ) {
        self.configuration = configuration
        self.timeSource = timeSource
        self.calendar = calendar
        self.logging = logging
        self.recentLogs = recentLogs
        self.database = database
        self.events = events
        self.settings = settings
        self.secrets = secrets
        self.errors = errors
        self.notifications = notifications
        self.organization = organization
        self.knowledge = knowledge
        self.intelligence = intelligence
        self.automation = automation
        self.search = search
        self.analytics = analytics
        self.sync = sync
        self.documentFiles = documentFiles
        self.plugins = plugins
        self.commands = commands
        self.home = home
        self.widgets = widgets
        self.focus = focus
    }

    /// Whether the assistant has a model and credentials to answer with.
    public func isAssistantConfigured() async -> Bool {
        await IntelligenceIntegration.isConfigured(settings: settings, providers: intelligence.providers, secrets: secrets)
    }

    /// Today in the user's calendar.
    public var today: CalendarDate {
        CalendarDate(timeSource.now(), calendar: calendar)
    }
}
