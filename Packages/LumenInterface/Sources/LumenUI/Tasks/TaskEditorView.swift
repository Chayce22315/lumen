import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Task details: everything about one task, saved together.
struct TaskEditorView: View {
    let services: LumenServices
    let model: AppModel
    @State private var editor: TaskEditorViewModel
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(taskID: TaskItem.ID, services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _editor = State(initialValue: TaskEditorViewModel(taskID: taskID, services: services))
    }

    var body: some View {
        Group {
            switch editor.state {
            case .idle, .loading:
                SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
            case .failed(let error):
                StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
            case .loaded:
                form
            }
        }
        .lumenScreenBackground()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await editor.save() } }
                    .disabled(!editor.hasChanges || editor.isSaving)
            }
        }
        .task { await editor.load() }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete task and subtasks", role: .destructive) {
                Task { if await editor.delete() { dismiss() } }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 0) {
                    CompletionToggle(isComplete: editor.original?.status == .done, label: "Completed") {
                        Task { await editor.toggleCompletion() }
                    }
                    .padding(.leading, -LumenSpace.s)
                    TextField("Title", text: $editor.title, axis: .vertical)
                        .lumenText(.title)
                        .padding(.top, LumenSpace.s)
                }
                TextField("Notes", text: $editor.notes, axis: .vertical)
                    .lumenText(.body)
                    .lineLimit(3...12)
            }
            if let error = editor.error {
                Section { Text(error.message).foregroundStyle(LumenColor.danger) }
            }
            scheduleSection
            Section("Organize") {
                Picker("Priority", selection: $editor.priority) {
                    ForEach(TaskPriority.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Project", selection: $editor.projectID) {
                    Text("None").tag(Project.ID?.none)
                    ForEach(editor.projects) { project in
                        Text(project.name).tag(Project.ID?.some(project.id))
                    }
                }
                TagEditor(tags: $editor.tags)
            }
            subtasksSection
            if !editor.blockers.isEmpty {
                Section("Waiting on") {
                    ForEach(editor.blockers) { blocker in
                        HStack {
                            Image(systemName: blocker.isOpen ? "hourglass" : "checkmark.circle.fill")
                                .foregroundStyle(blocker.isOpen ? LumenColor.warning : LumenColor.success)
                            Text(blocker.title)
                            Spacer()
                            Button("Remove") { Task { await editor.removeBlocker(blocker.id) } }
                                .buttonStyle(.lumenQuiet)
                        }
                    }
                }
            }
            Section {
                Button("Delete task", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Due date", isOn: Binding(
                get: { editor.dueDate != nil },
                set: { editor.dueDate = $0 ? (editor.dueDate ?? services.today) : nil }
            ))
            if let due = editor.dueDate {
                DatePicker("Due", selection: Binding(
                    get: { due.startDate(in: services.calendar) },
                    set: { editor.dueDate = CalendarDate($0, calendar: services.calendar) }
                ), displayedComponents: .date)
                Toggle("Time", isOn: Binding(
                    get: { editor.dueTime != nil },
                    set: { editor.dueTime = $0 ? (editor.dueTime ?? TimeOfDay.nine) : nil }
                ))
                if let time = editor.dueTime {
                    DatePicker("At", selection: Binding(
                        get: { time.date(on: due, calendar: services.calendar) },
                        set: { editor.dueTime = TimeOfDay($0, calendar: services.calendar) }
                    ), displayedComponents: .hourAndMinute)
                }
                RecurrencePicker(rule: $editor.recurrence)
                ReminderPicker(reminder: $editor.reminder)
            }
        }
    }

    private var subtasksSection: some View {
        Section("Subtasks") {
            ForEach(editor.subtasks) { subtask in
                HStack(spacing: 0) {
                    CompletionToggle(isComplete: subtask.status == .done, label: "Complete \(subtask.title)") {
                        Task { await editor.toggleSubtask(subtask.id) }
                    }
                    .padding(.leading, -LumenSpace.s)
                    Text(subtask.title)
                        .foregroundStyle(subtask.status == .done ? LumenColor.textTertiary : LumenColor.textPrimary)
                        .strikethrough(subtask.status == .done)
                }
            }
            HStack {
                TextField("Add a subtask", text: $editor.newSubtaskTitle)
                    .onSubmit { Task { await editor.addSubtask() } }
                Button { Task { await editor.addSubtask() } } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(editor.newSubtaskTitle.isEmpty)
                    .accessibilityLabel("Add subtask")
            }
        }
    }
}

/// Repeat options for a due date.
struct RecurrencePicker: View {
    @Binding var rule: RecurrenceRule?

    private let options: [(String, RecurrenceRule?)] = [
        ("Never", nil),
        ("Every day", .daily),
        ("Every weekday", .weekdaysOnly),
        ("Every week", .weekly),
        ("Every 2 weeks", RecurrenceRule(frequency: .weekly, interval: 2)),
        ("Every month", .monthly),
        ("Every year", .yearly),
    ]

    var body: some View {
        Picker("Repeat", selection: Binding(
            get: { options.firstIndex { $0.1 == rule } ?? -1 },
            set: { index in rule = options.indices.contains(index) ? options[index].1 : rule }
        )) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].0).tag(index)
            }
            if options.firstIndex(where: { $0.1 == rule }) == nil, let rule {
                Text(rule.summary).tag(-1)
            }
        }
    }
}

/// Reminder options relative to the due time.
struct ReminderPicker: View {
    @Binding var reminder: ReminderSpec?

    private let options: [(String, ReminderSpec?)] = [
        ("None", nil),
        ("At time of due", .atDue),
        ("5 minutes before", .minutesBefore(5)),
        ("15 minutes before", .minutesBefore(15)),
        ("1 hour before", .minutesBefore(60)),
        ("1 day before", .minutesBefore(1_440)),
    ]

    var body: some View {
        Picker("Remind me", selection: Binding(
            get: { options.firstIndex { $0.1 == reminder } ?? 0 },
            set: { reminder = options[$0].1 }
        )) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].0).tag(index)
            }
        }
    }
}

/// Inline tag editing: existing tags as chips, a field to add more.
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LumenSpace.s) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Chip("#\(tag)", symbolName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                }
            }
            TextField("Add tag", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    let cleaned = TaskValidator.normalizedTags([draft])
                    tags.append(contentsOf: cleaned.filter { !tags.contains($0) })
                    draft = ""
                }
        }
    }
}
