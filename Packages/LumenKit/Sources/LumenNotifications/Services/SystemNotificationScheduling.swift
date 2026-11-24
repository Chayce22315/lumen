import Foundation

public enum NotificationAuthorization: String, Sendable, Codable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

/// A request for the operating system to show a notification.
public struct SystemNotificationRequest: Sendable, Hashable {
    public var identifier: String
    public var title: String
    public var body: String
    public var categoryIdentifier: String
    /// `nil` delivers as soon as possible.
    public var fireDate: Date?
    /// Deep link opened when the notification is tapped (`lumen://entity/task:…`).
    public var deepLink: String?

    public init(identifier: String, title: String, body: String, categoryIdentifier: String, fireDate: Date?, deepLink: String?) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.fireDate = fireDate
        self.deepLink = deepLink
    }
}

/// The operating system's notification scheduler.
public protocol SystemNotificationScheduling: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ request: SystemNotificationRequest) async throws
    func cancel(identifiers: [String]) async
}
