#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// `SystemNotificationScheduling` backed by `UNUserNotificationCenter`.
public struct UserNotificationScheduler: SystemNotificationScheduling {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func schedule(_ request: SystemNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = request.categoryIdentifier
        content.threadIdentifier = request.categoryIdentifier
        content.sound = .default
        if let deepLink = request.deepLink {
            content.userInfo = ["deepLink": deepLink]
        }
        let trigger: UNNotificationTrigger?
        if let fireDate = request.fireDate {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = nil
        }
        let notification = UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(notification)
    }

    public func cancel(identifiers: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
#endif
