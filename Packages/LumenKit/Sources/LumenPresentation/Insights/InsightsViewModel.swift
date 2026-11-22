import Foundation
import Observation
import LumenFoundation
import LumenAnalytics
import LumenApplication

/// Insights: a weekly or monthly report with chart series, comparisons and insights.
@MainActor
@Observable
public final class InsightsViewModel {
    public enum Period: String, Sendable, Hashable, CaseIterable, Identifiable {
        case week
        case month
        case quarter

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .quarter: return "90 days"
            }
        }
    }

    public var period: Period = .week {
        didSet { Task { await load() } }
    }
    public private(set) var state: LoadState<PeriodReport> = .idle
    public private(set) var isCollectionEnabled = true

    private let services: LumenServices

    public init(services: LumenServices) {
        self.services = services
    }

    public func load() async {
        if state.value == nil { state = .loading }
        let today = services.today
        let range: DayRange
        switch period {
        case .week: range = .thisWeek(today: today, calendar: services.calendar)
        case .month: range = .thisMonth(today: today)
        case .quarter: range = .lastDays(90, endingOn: today)
        }
        do {
            isCollectionEnabled = await services.analytics.service.isCollectionEnabled()
            state = .loaded(try await services.analytics.service.report(signals: services.analytics.signals, range: range, today: today, insightLimit: 4))
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    /// The report as Markdown for sharing.
    public var markdown: String? {
        state.value?.markdown()
    }

    public func setCollectionEnabled(_ enabled: Bool) async {
        do {
            try await services.analytics.service.setCollectionEnabled(enabled)
            isCollectionEnabled = enabled
        } catch {
            services.errors.report(error, context: "Changing analytics collection")
        }
    }

    public func eraseAllData() async {
        do {
            try await services.analytics.service.eraseAllData()
            await load()
        } catch {
            services.errors.report(error, context: "Erasing analytics")
        }
    }
}
