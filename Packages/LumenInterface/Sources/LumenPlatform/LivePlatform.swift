import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenApplication
import LumenSync
import LumenWidgetData
#if canImport(WidgetKit)
@preconcurrency import WidgetKit
#endif

/// Builds the production configuration and platform services for the app target.
public enum LivePlatform {
    public static let calendarSource: EventKitCalendarSource = EventKitCalendarSource()

    public static func configuration(bundle: Bundle = .main) -> AppConfiguration {
        let directory = SharedContainer.directory() ?? SharedContainer.fallbackDirectory()
        let info = bundle.infoDictionary ?? [:]
        #if DEBUG
        let flavor = AppConfiguration.Flavor.debug
        #else
        let flavor = AppConfiguration.Flavor.release
        #endif
        return AppConfiguration(
            flavor: flavor,
            dataDirectory: directory,
            appGroupIdentifier: SharedContainer.directory() == nil ? nil : SharedContainer.appGroupIdentifier,
            keychainService: "app.lumen.secrets",
            logSubsystem: bundle.bundleIdentifier ?? "app.lumen",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info["CFBundleVersion"] as? String ?? "0"
        )
    }

    /// Info.plist key naming the build's iCloud container (for example `iCloud.app.lumen`).
    /// Missing or empty: no sync transport, and Settings explains that sync isn't set up.
    public static let cloudKitContainerKey = "LumenCloudKitContainerIdentifier"

    /// The iCloud container this build syncs through, if it has one.
    public static func cloudKitContainerIdentifier(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: cloudKitContainerKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// CloudKit sync, only for a build configured with an iCloud container: creating a
    /// `CKContainer` without the matching entitlement terminates the app, so nothing CloudKit is
    /// touched otherwise.
    static func syncTransport(for configuration: AppConfiguration, bundle: Bundle = .main) -> (any SyncTransport)? {
        #if canImport(CloudKit)
        guard let identifier = cloudKitContainerIdentifier(bundle: bundle) else { return nil }
        let logging = LoggingSystem(sinks: [UnifiedLogSink(subsystem: configuration.logSubsystem)])
        return CloudSyncTransport(database: CloudKitRecordDatabase(containerIdentifier: identifier), logger: logging.logger("sync.cloudkit"))
        #else
        return nil
        #endif
    }

    public static func services(for configuration: AppConfiguration) -> PlatformServices {
        var platform = PlatformServices(
            secrets: KeychainSecretStore(service: configuration.keychainService),
            notificationScheduler: UserNotificationScheduler(),
            externalCalendar: calendarSource,
            syncTransport: syncTransport(for: configuration),
            additionalLogSinks: [UnifiedLogSink(subsystem: configuration.logSubsystem)],
            reloadWidgets: {
                #if canImport(WidgetKit)
                Task { @MainActor in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                #endif
            }
        )
        platform.focusActivities = LiveActivityFocusPresenter()
        if CoreSpotlightIndex.isSupported {
            platform.systemSearchIndex = CoreSpotlightIndex()
        }
        return platform
    }

    /// The fully configured services for the running app.
    public static func makeServices(mode: LaunchMode = .resolve()) async throws -> LumenServices {
        switch mode {
        case .standard:
            let configuration = configuration()
            return try await LumenBootstrap.make(configuration: configuration, platform: services(for: configuration).addingDocumentTextExtractors(documentTextExtractors))
        case .uiTesting:
            let configuration = try uiTestingConfiguration()
            let platform = PlatformServices(
                secrets: InMemorySecretStore(),
                notificationScheduler: InertNotificationScheduler(),
                httpTransport: OfflineTransport()
            )
            return try await LumenBootstrap.make(configuration: configuration, platform: platform)
        }
    }

    /// An empty in-memory store in a fresh scratch directory, so every UI test launch starts from
    /// nothing and never touches the user's data, Keychain, calendars or notifications.
    static func uiTestingConfiguration() throws -> AppConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenUITesting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppConfiguration(flavor: .test, dataDirectory: directory, keychainService: "app.lumen.uitesting")
    }
}

/// How the process was launched.
public enum LaunchMode: Sendable, Equatable {
    /// The real app on the user's data.
    case standard
    /// Driven by the XCUITest target, which passes `uiTestingArgument`. Honoured in Debug builds
    /// only, so a release build can never be started on throwaway storage.
    case uiTesting

    public static let uiTestingArgument = "-LumenUITesting"

    public static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchMode {
        #if DEBUG
        if arguments.contains(uiTestingArgument) { return .uiTesting }
        #endif
        return .standard
    }
}
