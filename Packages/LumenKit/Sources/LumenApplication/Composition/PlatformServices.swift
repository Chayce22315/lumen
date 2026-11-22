import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenSync
import LumenPlugins
import LumenKnowledge

/// Everything that differs between the real app, previews and tests. The app target fills this
/// with Keychain, UserNotifications, EventKit and WidgetKit adapters; previews and tests use
/// `PlatformServices.ephemeral()`.
public struct PlatformServices: Sendable {
    public var secrets: any SecretStore
    public var notificationScheduler: any SystemNotificationScheduling
    public var externalCalendar: (any ExternalCalendarSource)?
    public var syncTransport: (any SyncTransport)?
    /// Where imported document files live. `nil` uses the configuration's documents directory
    /// (in memory for tests and previews).
    public var documentStorage: (any DocumentStorage)?
    public var additionalLogSinks: [any LogSink]
    /// Third-party plugins bundled with or installed into this build.
    public var plugins: [any LumenPlugin]
    /// Asks the system to reload widget timelines after a new snapshot was written.
    public var reloadWidgets: @Sendable () -> Void

    public init(
        secrets: any SecretStore,
        notificationScheduler: any SystemNotificationScheduling,
        externalCalendar: (any ExternalCalendarSource)? = nil,
        syncTransport: (any SyncTransport)? = nil,
        documentStorage: (any DocumentStorage)? = nil,
        additionalLogSinks: [any LogSink] = [],
        plugins: [any LumenPlugin] = [],
        reloadWidgets: @escaping @Sendable () -> Void = {}
    ) {
        self.secrets = secrets
        self.notificationScheduler = notificationScheduler
        self.externalCalendar = externalCalendar
        self.syncTransport = syncTransport
        self.documentStorage = documentStorage
        self.additionalLogSinks = additionalLogSinks
        self.plugins = plugins
        self.reloadWidgets = reloadWidgets
    }

    /// In-memory secrets and a scheduler that delivers nothing — for previews and tests only.
    public static func ephemeral() -> PlatformServices {
        PlatformServices(secrets: InMemorySecretStore(), notificationScheduler: InertNotificationScheduler())
    }
}

/// A scheduler for environments without system notifications (previews, tests, Linux tools).
/// It reports `.notDetermined` so the interface shows the "enable notifications" state.
public struct InertNotificationScheduler: SystemNotificationScheduling {
    public init() {}
    public func authorization() async -> NotificationAuthorization { .notDetermined }
    public func requestAuthorization() async throws -> Bool { false }
    public func schedule(_ request: SystemNotificationRequest) async throws {}
    public func cancel(identifiers: [String]) async {}
}
