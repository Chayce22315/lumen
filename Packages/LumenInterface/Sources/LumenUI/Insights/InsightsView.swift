import SwiftUI
import Charts
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenAnalytics

/// Productivity report: completed work over time, comparisons and insights.
struct InsightsView: View {
    let services: LumenServices
    @State private var insights: InsightsViewModel

    init(services: LumenServices) {
        self.services = services
        _insights = State(initialValue: InsightsViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumenSpace.xl) {
                Picker("Period", selection: $insights.period) {
                    ForEach(InsightsViewModel.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch insights.state {
                case .idle, .loading:
                    SkeletonRows(count: 4)
                case .failed(let error):
                    StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
                case .loaded(let report):
                    ReportView(report: report, calendar: services.calendar)
                }
                if !insights.isCollectionEnabled {
                    Text("Activity collection is off. Turn it on in Settings › Privacy to keep insights up to date.")
                        .lumenText(.footnote)
                        .foregroundStyle(LumenColor.textSecondary)
                }
            }
            .padding(LumenSpace.screen)
            .frame(maxWidth: LumenLayout.readableWidth * 1.3)
            .frame(maxWidth: .infinity)
        }
        .lumenScreenBackground()
        .navigationTitle("Insights")
        .toolbar {
            if let markdown = insights.markdown {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: markdown) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share report")
                }
            }
        }
        .task { await insights.load() }
    }
}

private struct ReportView: View {
    let report: PeriodReport
    let calendar: Calendar
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.xl) {
            HStack(spacing: LumenSpace.m) {
                StatTile(title: "Completed", value: "\(report.completed)", change: report.completedComparison.percentChange)
                StatTile(title: "Streak", value: "\(report.currentStreak) d", change: nil)
                if let created = report.created {
                    StatTile(title: "Added", value: "\(created)", change: report.createdComparison?.percentChange)
                }
            }
            VStack(alignment: .leading, spacing: LumenSpace.s) {
                SectionHeader("Completed per day")
                Chart(report.dailyCompleted.points, id: \.day) { point in
                    BarMark(
                        x: .value("Day", point.day.startDate(in: calendar), unit: .day),
                        y: .value(report.unit.plural.capitalized, appeared || reduceMotion ? point.value : 0)
                    )
                    .foregroundStyle(LumenColor.accent.gradient)
                    .cornerRadius(3)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
                .lumenSurface()
                .onAppear { withAnimation(.lumenSmooth) { appeared = true } }
            }
            if !report.insights.isEmpty {
                VStack(alignment: .leading, spacing: LumenSpace.s) {
                    SectionHeader("Insights")
                    ForEach(report.insights) { insight in
                        HStack(alignment: .top, spacing: LumenSpace.m) {
                            Image(systemName: symbol(for: insight.tone))
                                .foregroundStyle(tint(for: insight.tone))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.title).lumenText(.headline)
                                Text(insight.detail).lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lumenSurface(padding: LumenSpace.m)
                    }
                }
            }
            if let weekday = report.bestWeekday {
                Text("Your most productive day is \(Calendar.current.weekdaySymbols[(weekday.rawValue % 7)]).")
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textSecondary)
            }
        }
    }

    private func symbol(for tone: Insight.Tone) -> String {
        switch tone {
        case .positive: return "arrow.up.right.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private func tint(for tone: Insight.Tone) -> Color {
        switch tone {
        case .positive: return LumenColor.success
        case .attention: return LumenColor.warning
        default: return LumenColor.accent
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let change: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.xs) {
            Text(title).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
            Text(value).lumenText(.title).foregroundStyle(LumenColor.textPrimary).contentTransition(.numericText())
            if let change {
                Label("\(change >= 0 ? "+" : "")\(Int(change.rounded()))%", systemImage: change >= 0 ? "arrow.up" : "arrow.down")
                    .lumenText(.caption)
                    .foregroundStyle(change >= 0 ? LumenColor.success : LumenColor.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenSurface(padding: LumenSpace.m)
        .accessibilityElement(children: .combine)
    }
}
