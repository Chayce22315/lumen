import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenApplication
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

    public static func services(for configuration: AppConfiguration) -> PlatformServices {
        PlatformServices(
            secrets: KeychainSecretStore(service: configuration.keychainService),
            notificationScheduler: UserNotificationScheduler(),
            externalCalendar: calendarSource,
            additionalLogSinks: [UnifiedLogSink(subsystem: configuration.logSubsystem)],
            reloadWidgets: {
                #if canImport(WidgetKit)
                Task { @MainActor in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                #endif
            }
        )
    }

    /// The fully configured services for the running app.
    public static func makeServices() async throws -> LumenServices {
        let configuration = configuration()
        return try await LumenBootstrap.make(configuration: configuration, platform: services(for: configuration))
    }
}
