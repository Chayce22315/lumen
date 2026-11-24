import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// A week strip or a month grid over the agenda.
struct CalendarView: View {
    let services: LumenServices
    let model: AppModel
    @State private var calendar: CalendarViewModel
    @State private var isCreatingEvent = false
    @State private var editingSystemEvent: SystemEventSelection?
    @Namespace private var selection

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _calendar = State(initialValue: CalendarViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { calendar.mode }, set: { mode in Task { await calendar.setMode(mode) } })) {
                ForEach(CalendarMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LumenSpace.screen)
            .padding(.top, LumenSpace.s)
            switch calendar.mode {
            case .week: weekStrip
            case .month: MonthGridView(calendar: calendar, selection: selection)
            }
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
        .sheet(item: $editingSystemEvent) { selected in
            NavigationStack { EventEditorView(services: services, systemEventIdentifier: selected.id) }
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
        .lumenAnimation(.lumenSnappy, value: calendar.selectedDay)
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
                            AgendaRow(entry: entry, labels: calendar.labels) { identifier in
                                editingSystemEvent = SystemEventSelection(id: identifier)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// The system event whose editor sheet is open.
private struct SystemEventSelection: Identifiable {
    let id: String
}

/// A month of days with dots for events and tasks.
private struct MonthGridView: View {
    let calendar: CalendarViewModel
    let selection: Namespace.ID
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: LumenSpace.xs) {
            HStack {
                Button { Task { await calendar.moveMonth(by: -1) } } label: { Image(systemName: "chevron.left") }
                    .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(calendar.monthTitle)
                    .lumenText(.headline)
                    .foregroundStyle(LumenColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { Task { await calendar.moveMonth(by: 1) } } label: { Image(systemName: "chevron.right") }
                    .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                    .accessibilityLabel("Next month")
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Weekday.allCases, id: \.self) { weekday in
                    Text(weekday.shortName.prefix(1))
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textTertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(calendar.month.weeks.joined().map { $0 }, id: \.self) { day in
                    MonthDayCell(
                        day: day,
                        isInMonth: calendar.month.contains(day),
                        isToday: day == calendar.today,
                        isSelected: day == calendar.selectedDay,
                        density: calendar.density(on: day),
                        selection: selection
                    ) {
                        Task { await calendar.select(day) }
                    }
                    .accessibilityLabel(calendar.accessibilityLabel(for: day))
                    .accessibilityAddTraits(day == calendar.selectedDay ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, LumenSpace.s)
        .padding(.bottom, LumenSpace.s)
        .lumenAnimation(.lumenSnappy, value: calendar.selectedDay)
        .lumenAnimation(.lumenSmooth, value: calendar.month)
    }
}

private struct MonthDayCell: View {
    let day: CalendarDate
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let density: DayDensity
    let selection: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(day.day)")
                    .lumenText(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .frame(minWidth: 30, minHeight: 30)
                    .background {
                        if isSelected {
                            Circle().fill(LumenColor.accentFill)
                                .matchedGeometryEffect(id: "selected-day", in: selection)
                        }
                    }
                DensityDots(density: density, isInMonth: isInMonth)
            }
            .frame(maxWidth: .infinity, minHeight: LumenLayout.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var numberColor: Color {
        if isSelected { return LumenColor.onAccent }
        if !isInMonth { return LumenColor.textTertiary }
        return isToday ? LumenColor.accentText : LumenColor.textPrimary
    }
}

/// Up to three dots: events in the accent color, tasks in the secondary text color.
private struct DensityDots: View {
    let density: DayDensity
    let isInMonth: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(density.events, 2), id: \.self) { _ in
                Circle().fill(LumenColor.accent).frame(width: 4, height: 4)
            }
            ForEach(0..<min(density.tasks, 3 - min(density.events, 2)), id: \.self) { _ in
                Circle().fill(LumenColor.textSecondary).frame(width: 4, height: 4)
            }
        }
        .frame(height: 4)
        .opacity(isInMonth ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}

private struct AgendaRow: View {
    let entry: AgendaEntry
    let labels: DateLabels
    let openSystemEvent: (String) -> Void

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
            switch occurrence.source {
            case .local(let id):
                NavigationLink(value: AppDestination.entity(EntityReference(kind: .calendarEvent, id: id))) { row }
            case .external(let identifier, let calendarName):
                Button { openSystemEvent(identifier) } label: { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this event from \(calendarName)")
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
