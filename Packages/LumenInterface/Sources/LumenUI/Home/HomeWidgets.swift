import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization
import LumenAnalytics
import LumenKnowledge

/// One dashboard widget.
struct HomeWidgetView: View {
    let item: DashboardItem
    let snapshot: HomeSnapshot
    let home: HomeViewModel
    let services: LumenServices
    let model: AppModel
    let zoom: Namespace.ID

    var body: some View {
        switch item.kind {
        case .suggestions: SuggestionsWidget(suggestions: snapshot.suggestions, model: model)
        case .focus: FocusWidget(snapshot: snapshot, home: home, services: services, model: model, zoom: zoom, compact: item.size == .compact)
        case .agenda: AgendaWidget(snapshot: snapshot, services: services, model: model)
        case .projects: ProjectsWidget(projects: snapshot.projects, model: model, zoom: zoom)
        case .quickActions: QuickActionsWidget(model: model)
        case .insights: InsightsWidget(insights: snapshot.insights, streak: snapshot.currentStreak, model: model)
        case .activity: ActivityWidget(items: snapshot.activity, services: services, model: model)
        case .recentNotes: RecentNotesWidget(notes: snapshot.recentNotes, model: model, zoom: zoom)
        }
    }
}

private struct SuggestionsWidget: View {
    let suggestions: [Suggestion]
    let model: AppModel

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: LumenSpace.s) {
                ForEach(suggestions) { suggestion in
                    Button {
                        model.router.open(suggestion.destination)
                    } label: {
                        HStack(alignment: .top, spacing: LumenSpace.m) {
                            IconBadge(suggestion.symbolName)
                            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                                Text(suggestion.title).lumenText(.headline).foregroundStyle(LumenColor.textPrimary)
                                Text(suggestion.detail).lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LumenColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .lumenSurface(padding: LumenSpace.m)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }
}

private struct FocusWidget: View {
    let snapshot: HomeSnapshot
    let home: HomeViewModel
    let services: LumenServices
    let model: AppModel
    let zoom: Namespace.ID
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Today's focus") {
                Button("All") { model.router.open(.tasks(.today)) }
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.accentText)
            }
            let tasks = Array(snapshot.overview.focusTasks.prefix(compact ? 3 : 5))
            if tasks.isEmpty {
                Text("Nothing is due today. Capture something with ＋ or plan from your inbox.")
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lumenSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        FocusRow(task: task, today: snapshot.overview.day, home: home, model: model, zoom: zoom, labels: DateLabels(calendar: services.calendar, locale: .current))
                        if task.id != tasks.last?.id { HairlineDivider().padding(.leading, 52) }
                    }
                }
                .lumenSurface(padding: LumenSpace.xs)
            }
        }
    }
}

private struct FocusRow: View {
    let task: TaskItem
    let today: CalendarDate
    let home: HomeViewModel
    let model: AppModel
    let zoom: Namespace.ID
    let labels: DateLabels
    @State private var isDone = false

    var body: some View {
        HStack(spacing: 0) {
            CompletionToggle(isComplete: isDone, label: "Complete \(task.title)") {
                withAnimation(.lumenSnappy) { isDone = true }
                Task { await home.complete(task.id) }
            }
            Button {
                model.router.open(.entity(task.reference))
            } label: {
                VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                    Text(task.title)
                        .lumenText(.body)
                        .foregroundStyle(isDone ? LumenColor.textTertiary : LumenColor.textPrimary)
                        .strikethrough(isDone, color: LumenColor.textTertiary)
                        .lineLimit(2)
                    if let due = task.dueDate {
                        Text(labels.dueLabel(day: due, time: task.dueTime, today: today))
                            .lumenText(.caption)
                            .foregroundStyle(task.isOverdue(today: today) ? LumenColor.danger : LumenColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LumenSpace.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: AppDestination.entity(task.reference), in: zoom)
            if task.priority >= .high {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(task.priority == .urgent ? LumenColor.danger : LumenColor.warning)
                    .padding(.trailing, LumenSpace.m)
                    .accessibilityLabel("\(task.priority.title) priority")
            }
        }
    }
}

private struct AgendaWidget: View {
    let snapshot: HomeSnapshot
    let services: LumenServices
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Upcoming") {
                Button("Calendar") { model.router.open(.calendar) }
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.accentText)
            }
            let labels = DateLabels(calendar: services.calendar, locale: .current)
            VStack(alignment: .leading, spacing: LumenSpace.m) {
                if let next = snapshot.overview.nextEvent {
                    EventLine(title: next.title, detail: "\(labels.dayLabel(next.firstDay, today: snapshot.overview.day)), \(labels.timeLabel(next.start))", isNext: true)
                }
                ForEach(laterEvents.prefix(4), id: \.occurrence.id) { item in
                    EventLine(title: item.occurrence.title, detail: detail(for: item, labels: labels), isNext: false)
                }
                if snapshot.overview.nextEvent == nil && laterEvents.isEmpty {
                    Text("No events in the next few days.")
                        .lumenText(.subheadline)
                        .foregroundStyle(LumenColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lumenSurface()
        }
    }
}

extension AgendaWidget {
    struct DayEvent {
        let day: CalendarDate
        let occurrence: EventOccurrence
    }

    /// Events after today, excluding the one already shown as "next".
    var laterEvents: [DayEvent] {
        snapshot.upcoming.flatMap { day in
            (day.allDay + day.scheduled).compactMap { entry -> DayEvent? in
                guard case .event(let occurrence) = entry, occurrence.id != snapshot.overview.nextEvent?.id else { return nil }
                return DayEvent(day: day.day, occurrence: occurrence)
            }
        }
    }

    func detail(for item: DayEvent, labels: DateLabels) -> String {
        let day = labels.dayLabel(item.day, today: snapshot.overview.day)
        return item.occurrence.isAllDay ? day : "\(day), \(labels.timeLabel(item.occurrence.start))"
    }
}

private struct EventLine: View {
    let title: String
    let detail: String
    let isNext: Bool

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isNext ? LumenColor.accent : LumenColor.textTertiary)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lumenText(.body).foregroundStyle(LumenColor.textPrimary).lineLimit(1)
                Text(detail).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectsWidget: View {
    let projects: [ProjectSummary]
    let model: AppModel
    let zoom: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Active projects") {
                Button("All") { model.router.open(.tasks(.projects)) }
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.accentText)
            }
            if projects.isEmpty {
                Text("Projects group related tasks and track progress toward a date.")
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lumenSurface()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LumenSpace.m) {
                        ForEach(projects.prefix(6)) { summary in
                            Button {
                                model.router.open(.entity(summary.project.reference))
                            } label: {
                                ProjectTile(summary: summary)
                            }
                            .buttonStyle(.pressable)
                            .matchedTransitionSource(id: AppDestination.entity(summary.project.reference), in: zoom)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }
}

private struct ProjectTile: View {
    let summary: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.m) {
            HStack {
                ProgressRing(fraction: summary.progress.fractionComplete, tint: LumenColor.identity(summary.project.color.rawValue))
                    .frame(width: 28, height: 28)
                Spacer()
                if summary.progress.health == .atRisk || summary.progress.health == .offTrack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(summary.progress.health == .offTrack ? LumenColor.danger : LumenColor.warning)
                        .accessibilityLabel(summary.progress.health == .offTrack ? "Behind schedule" : "At risk")
                }
            }
            Text(summary.project.name)
                .lumenText(.headline)
                .foregroundStyle(LumenColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(summary.progress.nextAction?.title ?? "No next step")
                .lumenText(.caption)
                .foregroundStyle(LumenColor.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 168, alignment: .leading)
        .lumenSurface(padding: LumenSpace.m)
        .accessibilityElement(children: .combine)
    }
}

private struct QuickActionsWidget: View {
    let model: AppModel
    private let actions: [(String, String, String)] = [
        ("create.task", "Task", "plus.circle"),
        ("create.note", "Note", "square.and.pencil"),
        ("create.event", "Event", "calendar.badge.plus"),
        ("navigate.assistant", "Ask", "sparkles"),
    ]

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            ForEach(actions, id: \.0) { action in
                Button {
                    Task { await model.runCommand(action.0) }
                } label: {
                    VStack(spacing: LumenSpace.s) {
                        Image(systemName: action.2)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(LumenColor.accent)
                        Text(action.1)
                            .lumenText(.caption)
                            .foregroundStyle(LumenColor.textPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .lumenSurface(padding: LumenSpace.s)
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

private struct InsightsWidget: View {
    let insights: [Insight]
    let streak: Int
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Insights") {
                Button("More") { model.router.open(.insights) }
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.accentText)
            }
            VStack(alignment: .leading, spacing: LumenSpace.m) {
                if streak > 0 {
                    Label("\(streak)-day streak", systemImage: "flame")
                        .lumenText(.headline)
                        .foregroundStyle(LumenColor.warning)
                }
                ForEach(insights.prefix(2)) { insight in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
                        Text(insight.detail).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                    }
                }
                if insights.isEmpty && streak == 0 {
                    Text("Insights appear once you've used Lumen for a few days.")
                        .lumenText(.subheadline)
                        .foregroundStyle(LumenColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lumenSurface()
        }
    }
}

private struct ActivityWidget: View {
    let items: [ActivityItem]
    let services: LumenServices
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Recent activity")
            let labels = DateLabels(calendar: services.calendar, locale: .current)
            let now = services.timeSource.now()
            VStack(alignment: .leading, spacing: LumenSpace.m) {
                if items.isEmpty {
                    Text("Your recent changes will show here.")
                        .lumenText(.subheadline)
                        .foregroundStyle(LumenColor.textSecondary)
                }
                ForEach(items.prefix(6)) { item in
                    Button {
                        if let destination = item.destination { model.router.open(destination) }
                    } label: {
                        HStack(spacing: LumenSpace.m) {
                            Image(systemName: item.symbolName)
                                .foregroundStyle(LumenColor.textSecondary)
                                .frame(width: 20)
                            Text(item.title)
                                .lumenText(.subheadline)
                                .foregroundStyle(LumenColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(labels.relativeLabel(item.occurredAt, now: now))
                                .lumenText(.caption)
                                .foregroundStyle(LumenColor.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(item.destination == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lumenSurface()
        }
    }
}

private struct RecentNotesWidget: View {
    let notes: [Note]
    let model: AppModel
    let zoom: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Recent notes") {
                Button("Library") { model.router.open(.library) }
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.accentText)
            }
            if notes.isEmpty {
                Text("Notes you write appear here.")
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lumenSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(notes) { note in
                        Button {
                            model.router.open(.entity(note.reference))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? "Untitled note" : note.title).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
                                Text(note.excerpt).lumenText(.caption).foregroundStyle(LumenColor.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(LumenSpace.m)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: AppDestination.entity(note.reference), in: zoom)
                        if note.id != notes.last?.id { HairlineDivider().padding(.leading, LumenSpace.m) }
                    }
                }
                .lumenSurface(padding: 0)
            }
        }
    }
}
