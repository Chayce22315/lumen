import WidgetKit
import SwiftUI
import AppIntents
import LumenWidgetData
import LumenDesignSystem

@main
struct LumenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        FocusLiveActivity()
    }
}

/// Today's focus on the Home Screen (counts, tasks you can check off, the next event) and on the
/// Lock Screen (a progress ring, the next task, an inline summary).
struct TodayWidget: Widget {
    let kind = "app.lumen.widget.today"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TodayWidgetIntent.self, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .widgetURL(URL(string: "lumen://tasks/today"))
        }
        .configurationDisplayName("Today")
        .description("What's due today and what's next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Today"
    static let description = IntentDescription("Shows today's tasks.")
}

struct TodayEntry: TimelineEntry {
    let date: Date
    /// `nil` before the app has written its first snapshot, or without a shared App Group.
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
        content.containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            CircularAccessory(snapshot: entry.snapshot)
        case .accessoryRectangular:
            RectangularAccessory(snapshot: entry.snapshot)
        case .accessoryInline:
            InlineAccessory(snapshot: entry.snapshot)
        default:
            if let snapshot = entry.snapshot {
                if family == .systemSmall {
                    SmallTodayView(snapshot: snapshot)
                } else {
                    MediumTodayView(snapshot: snapshot)
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
    }

    /// Lock-screen widgets take the system's vibrant background; Home Screen ones use Lumen's.
    @ViewBuilder
    private var background: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: Color.clear
        default: LumenColor.background
        }
    }
}

// MARK: - Home Screen

/// A checkbox that completes the task through `CompleteTaskIntent`.
private struct TaskCheckbox: View {
    let task: WidgetSnapshot.TaskLine

    var body: some View {
        Button(intent: CompleteTaskIntent(taskID: task.id)) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.footnote)
                .foregroundStyle(task.isCompleted ? LumenColor.accent : (task.isOverdue ? LumenColor.danger : LumenColor.textTertiary))
        }
        .buttonStyle(.plain)
        .disabled(task.isCompleted)
        .accessibilityLabel(task.isCompleted ? "\(task.title), done" : "Complete \(task.title)")
    }
}

private struct TaskLineView: View {
    let task: WidgetSnapshot.TaskLine

    var body: some View {
        HStack(spacing: 6) {
            TaskCheckbox(task: task)
            Text(task.title)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? LumenColor.textTertiary : LumenColor.textPrimary)
            Spacer(minLength: 0)
            if let time = task.dueTime, !task.isCompleted {
                Text(time).font(.caption2).foregroundStyle(LumenColor.textSecondary)
            }
        }
    }
}

private struct SmallTodayView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today").font(.caption).foregroundStyle(LumenColor.textSecondary)
            Text("\(snapshot.dueToday)")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(LumenColor.textPrimary)
                .contentTransition(.numericText())
            Text(snapshot.dueToday == 1 ? "task due" : "tasks due")
                .font(.caption)
                .foregroundStyle(LumenColor.textSecondary)
            Spacer(minLength: 0)
            if let next = snapshot.tasks.first(where: { !$0.isCompleted }) ?? snapshot.tasks.first {
                TaskLineView(task: next)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediumTodayView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today").font(.caption).foregroundStyle(LumenColor.textSecondary)
                Text("\(snapshot.dueToday)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(LumenColor.textPrimary)
                    .contentTransition(.numericText())
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
                    TaskLineView(task: task)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Lock Screen

private struct CircularAccessory: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            let progress = snapshot.todayProgress
            Gauge(value: progress.fraction) {
                Image(systemName: "checkmark")
            } currentValueLabel: {
                Text("\(progress.remaining)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel(progress.total == 0 ? "Nothing due today" : "\(progress.completed) of \(progress.total) tasks done today")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkle")
            }
            .accessibilityLabel("Open Lumen")
        }
    }
}

private struct RectangularAccessory: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let snapshot {
                let remaining = snapshot.todayProgress.remaining
                Text(remaining == 0 ? "All done today" : (remaining == 1 ? "1 task left" : "\(remaining) tasks left"))
                    .font(.headline)
                    .widgetAccentable()
                if let next = snapshot.nextOpenTask {
                    Text(next.title).font(.body).lineLimit(1)
                    if let time = next.dueTime {
                        Text(time).font(.caption)
                    }
                } else if let event = snapshot.nextEvent {
                    Text(event.title).font(.body).lineLimit(1)
                    Text(event.start, style: .time).font(.caption)
                }
            } else {
                Text("Lumen").font(.headline).widgetAccentable()
                Text("Open Lumen to see today here.").font(.caption).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineAccessory: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            let remaining = snapshot.todayProgress.remaining
            if let next = snapshot.nextOpenTask {
                Text("\(remaining) left · \(next.title)")
            } else {
                Text("All done today")
            }
        } else {
            Text("Open Lumen")
        }
    }
}
