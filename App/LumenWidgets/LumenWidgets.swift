import WidgetKit
import SwiftUI
import AppIntents
import LumenWidgetData
import LumenDesignSystem

@main
struct LumenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

/// Today's focus: counts, the first tasks and the next event.
struct TodayWidget: Widget {
    let kind = "app.lumen.widget.today"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TodayWidgetIntent.self, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { LumenColor.background }
                .widgetURL(URL(string: "lumen://tasks/today"))
        }
        .configurationDisplayName("Today")
        .description("What's due today and what's next.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Today"
    static let description = IntentDescription("Shows today's tasks.")
}

struct TodayEntry: TimelineEntry {
    let date: Date
    /// `nil` before the app has written its first snapshot.
    let snapshot: WidgetSnapshot?
}

struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: nil)
    }

    func snapshot(for configuration: TodayWidgetIntent, in context: Context) async -> TodayEntry {
        currentEntry()
    }

    func timeline(for configuration: TodayWidgetIntent, in context: Context) async -> Timeline<TodayEntry> {
        // The app reloads timelines whenever its data changes; the refresh date covers day changes.
        Timeline(entries: [currentEntry()], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func currentEntry() -> TodayEntry {
        let directory = SharedContainer.directory() ?? SharedContainer.fallbackDirectory()
        let store = WidgetSnapshotStore(url: directory.appendingPathComponent(SharedContainer.snapshotFileName))
        do {
            return TodayEntry(date: Date(), snapshot: try store.read())
        } catch {
            // An unreadable snapshot shows the "open Lumen" state; the app rewrites it on next launch.
            return TodayEntry(date: Date(), snapshot: nil)
        }
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: small(snapshot)
            default: medium(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "sparkle").foregroundStyle(LumenColor.accent)
                Text("Open Lumen to see today here.")
                    .font(.footnote)
                    .foregroundStyle(LumenColor.textSecondary)
            }
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today").font(.caption).foregroundStyle(LumenColor.textSecondary)
            Text("\(snapshot.dueToday)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LumenColor.textPrimary)
            Text(snapshot.dueToday == 1 ? "task due" : "tasks due")
                .font(.caption)
                .foregroundStyle(LumenColor.textSecondary)
            Spacer(minLength: 0)
            if let first = snapshot.tasks.first {
                Text(first.title).font(.caption).lineLimit(2).foregroundStyle(LumenColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today").font(.caption).foregroundStyle(LumenColor.textSecondary)
                Text("\(snapshot.dueToday)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(LumenColor.textPrimary)
                if snapshot.overdue > 0 {
                    Text("\(snapshot.overdue) overdue").font(.caption).foregroundStyle(LumenColor.danger)
                }
                Spacer(minLength: 0)
                if let next = snapshot.nextEvent {
                    Text(next.title).font(.caption).lineLimit(1).foregroundStyle(LumenColor.textPrimary)
                    Text(next.start, style: .time).font(.caption2).foregroundStyle(LumenColor.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if snapshot.tasks.isEmpty {
                    Text("Nothing due today.").font(.caption).foregroundStyle(LumenColor.textSecondary)
                }
                ForEach(snapshot.tasks.prefix(4)) { task in
                    HStack(spacing: 6) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(task.isOverdue ? LumenColor.danger : LumenColor.textTertiary)
                        Text(task.title).font(.caption).lineLimit(1).foregroundStyle(LumenColor.textPrimary)
                        Spacer(minLength: 0)
                        if let time = task.dueTime {
                            Text(time).font(.caption2).foregroundStyle(LumenColor.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
