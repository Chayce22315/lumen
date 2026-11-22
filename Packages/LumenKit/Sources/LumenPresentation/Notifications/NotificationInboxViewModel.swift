import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenApplication

/// The notification inbox and notification preferences.
@MainActor
@Observable
public final class NotificationInboxViewModel {
    public private(set) var state: LoadState<[InboxNotification]> = .idle
    public private(set) var upcoming: [InboxNotification] = []
    public private(set) var unreadCount = 0
    public private(set) var preferences = NotificationPreferences()
    public private(set) var authorization: NotificationAuthorization = .notDetermined

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(services: LumenServices) {
        self.services = services
    }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["notifications"]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        let notifications = services.notifications
        do {
            state = .loaded(try await notifications.inbox())
            upcoming = try await notifications.upcoming(limit: 20)
            unreadCount = try await notifications.unreadCount()
            preferences = await notifications.preferences()
            authorization = await notifications.authorization()
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public func open(_ notification: InboxNotification, router: Router) async {
        await markRead(notification.id)
        if let entity = notification.entity {
            router.open(.entity(entity))
        }
    }

    public func markRead(_ id: InboxNotification.ID) async {
        await perform("Updating notifications") { try await $0.markRead(id) }
    }

    public func markAllRead() async {
        await perform("Updating notifications") { try await $0.markAllRead() }
    }

    public func delete(_ id: InboxNotification.ID) async {
        await perform("Deleting a notification") { try await $0.delete(id) }
    }

    public func requestAuthorization() async {
        do {
            _ = try await services.notifications.requestAuthorization()
        } catch {
            services.errors.report(error, context: "Requesting notification permission")
        }
        authorization = await services.notifications.authorization()
    }

    // MARK: - Preferences

    public func setInbox(_ enabled: Bool, for category: NotificationCategory) async {
        var updated = preferences
        var preference = updated.preference(for: category)
        preference.showsInInbox = enabled
        updated.categories[category] = preference
        await save(updated)
    }

    public func setAlerts(_ enabled: Bool, for category: NotificationCategory) async {
        var updated = preferences
        var preference = updated.preference(for: category)
        preference.deliversAlert = enabled
        updated.categories[category] = preference
        await save(updated)
    }

    public func setQuietHours(_ quietHours: QuietHours?) async {
        var updated = preferences
        updated.quietHours = quietHours
        await save(updated)
    }

    private func save(_ updated: NotificationPreferences) async {
        do {
            try await services.notifications.updatePreferences(updated)
            preferences = updated
        } catch {
            services.errors.report(error, context: "Saving notification preferences")
        }
    }

    private func perform(_ context: String, _ work: (NotificationService) async throws -> Void) async {
        do {
            try await work(services.notifications)
            await load()
        } catch {
            services.errors.report(error, context: context)
        }
    }
}
