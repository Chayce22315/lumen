import Foundation
import LumenCore

/// Event names and settings owned by analytics.
public enum AnalyticsEvents {
    /// The module segment of analytics' own events. The collector never records events of its own
    /// module, so erasing analytics data cannot immediately re-create a row about the erasure.
    public static let module = "analytics"

    /// Published after all analytics data was erased, so screens showing statistics can refresh.
    public static let dataErased: EventName = "analytics.data.erased"
}

/// Analytics preferences. Device-local, like every setting.
public enum AnalyticsSettings {
    /// Whether events are recorded. On by default; analytics never leaves the device.
    public static let collectionEnabled = SettingKey("analytics.collectionEnabled", default: true)
}
