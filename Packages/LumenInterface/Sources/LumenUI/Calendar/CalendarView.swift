import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// A week strip over a seven-day agenda.
struct CalendarView: View {
    let services: LumenServices
    let model: AppModel
    @State private var calendar: CalendarViewModel
    @State private var isCreatingEvent = false
    @Namespace private var selection

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _calendar = State(initialValue: CalendarViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            weekStrip
            HairlineDivider()
            agenda
        }
        .lumenScreenBackground()
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Today") { Task { await calendar.goToToday() } }
                    .disabled(calendar.isShowingToday)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreatingEvent = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New event")
            }
        }
        .sheet(isPresented: $isCreatingEvent) {
            NavigationStack { EventEditorView(services: services, eventID: nil, day: calendar.selectedDay) }
        }
        .task { await calendar.start() }
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            Button { Task { await calendar.moveWeek(by: -1) } } label: { Image(systemName: "chevron.left") }
                .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                .accessibilityLabel("Previous week")
            ForEach(calendar.weekDays, id: \.self) { day in
                Button {
                    Task { await calendar.select(day) }
                } label: {
                    VStack(spacing: LumenSpace.xs) {
                        Text(Weekday(rawValue: day.isoWeekday)?.shortName.prefix(1) ?? "")
                            .lumenText(.caption)
                            .foregroundStyle(LumenColor.textTertiary)
                        Text("\(day.day)")
                            .lumenText(.headline)
                            .foregroundStyle(day == calendar.selectedDay ? LumenColor.onAccent : (day == calendar.today ? LumenColor.accentText : LumenColor.textPrimary))
                            .frame(width: 32, height: 32)
                            .background {
                                if day == calendar.selectedDay {
                                    Circle().fill(LumenColor.accentFill)
                                        .matchedGeometryEffect(id: "selected-day", in: selection)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.labels.dayLabel(day, today: calendar.today))
                .accessibilityAddTraits(day == calendar.selectedDay ? .isSelected : [])
            }
            Button { Task { await calendar.moveWeek(by: 1) } } label: { Image(systemName: "chevron.right") }
                .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                .accessibilityLabel("Next week")
        }
        .padding(.vertical, LumenSpace.s)
        .animation(.lumenSnappy, value: calendar.selectedDay)
    }

    @ViewBuilder
    private var agenda: some View {
        switch calendar.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
        case .loaded(let days):
            List {
                ForEach(days) { day in
                    Section(calendar.labels.dayLabel(day.day, today: calendar.today)) {
                        if day.isEmpty {
                            Text("Nothing scheduled").lumenText(.subheadline).foregroundStyle(LumenColor.textTertiary)
                        }
                        ForEach(day.allDay + day.scheduled + day.anytime) { entry in
                            AgendaRow(entry: entry, labels: calendar.labels)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct AgendaRow: View {
    let entry: AgendaEntry
    let labels: DateLabels

    var body: some View {
        switch entry {
        case .event(let occurrence):
            let row = HStack(spacing: LumenSpace.m) {
                RoundedRectangle(cornerRadius: 2).fill(LumenColor.identity(occurrence.color.rawValue)).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(occurrence.title).lumenText(.body)
                    Text(occurrence.isAllDay ? "All day" : "\(labels.timeLabel(occurrence.start)) – \(labels.timeLabel(occurrence.end))")
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textSecondary)
                }
                Spacer()
                if case .external(_, let calendarName) = occurrence.source {
                    Text(calendarName).lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
                }
            }
            if case .local(let id) = occurrence.source {
                NavigationLink(value: AppDestination.entity(EntityReference(kind: .calendarEvent, id: id))) { row }
            } else {
                row
            }
        case .task(let task):
            NavigationLink(value: AppDestination.entity(task.reference)) {
                HStack(spacing: LumenSpace.m) {
                    Image(systemName: "circle").foregroundStyle(LumenColor.textTertiary)
                    Text(task.title).lumenText(.body)
                    Spacer()
                    if let time = task.dueTime {
                        Text(labels.timeLabel(time)).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                    }
                }
            }
        }
    }
}
