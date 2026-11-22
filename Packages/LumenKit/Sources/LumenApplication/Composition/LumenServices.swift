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

public struct OrganizationServices: Sendable {
    public let tasks: TaskService
    public let projects: ProjectService
    public let calendars: CalendarService
    public let agenda: AgendaService
    public let reminders: ReminderCoordinator
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
    public let search: SearchServices
    public let analytics: AnalyticsServices
    public let sync: SyncEngine
    public let plugins: PluginServices
    public let commands: CommandCenter
    public let home: HomeService
    public let widgets: WidgetSnapshotPublisher

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
        search: SearchServices,
        analytics: AnalyticsServices,
        sync: SyncEngine,
        plugins: PluginServices,
        commands: CommandCenter,
        home: HomeService,
        widgets: WidgetSnapshotPublisher
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
        self.search = search
        self.analytics = analytics
        self.sync = sync
        self.plugins = plugins
        self.commands = commands
        self.home = home
        self.widgets = widgets
    }

    /// Today in the user's calendar.
    public var today: CalendarDate {
        CalendarDate(timeSource.now(), calendar: calendar)
    }
}
