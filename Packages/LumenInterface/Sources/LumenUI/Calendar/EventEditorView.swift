import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Creating or editing an event in a Lumen calendar or one of the user's system calendars.
struct EventEditorView: View {
    @State private var editor: EventEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(services: LumenServices, eventID: CalendarEvent.ID?, day: CalendarDate? = nil) {
        _editor = State(initialValue: EventEditorViewModel(services: services, eventID: eventID, day: day))
    }

    init(services: LumenServices, systemEventIdentifier: String) {
        _editor = State(initialValue: EventEditorViewModel(services: services, systemEventIdentifier: systemEventIdentifier))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $editor.title)
                TextField("Location", text: $editor.location)
            }
            .disabled(editor.isReadOnly)
            Section {
                Toggle("All day", isOn: $editor.isAllDay)
                DatePicker("Starts", selection: $editor.start, displayedComponents: editor.isAllDay ? .date : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $editor.end, in: editor.start..., displayedComponents: editor.isAllDay ? .date : [.date, .hourAndMinute])
                repeatRow
            } footer: {
                if !editor.compatibilityNotes.isEmpty {
                    VStack(alignment: .leading, spacing: LumenSpace.xs) {
                        ForEach(editor.compatibilityNotes, id: \.self) { Text($0) }
                    }
                }
            }
            .disabled(editor.isReadOnly)
            calendarSection
            Section {
                Picker("Alert", selection: Binding(
                    get: { editor.reminderOffsets.first ?? -1 },
                    set: { editor.reminderOffsets = $0 < 0 ? [] : [$0] }
                )) {
                    Text("None").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("1 day before").tag(1_440)
                }
            } footer: {
                if editor.otherAlertCount > 0 {
                    Text(editor.otherAlertCount == 1
                         ? "1 more alert set in another app is kept."
                         : "\(editor.otherAlertCount) more alerts set in another app are kept.")
                }
            }
            .disabled(editor.isReadOnly)
            Section {
                TextField("Notes", text: $editor.notes, axis: .vertical).lineLimit(3...10)
            }
            .disabled(editor.isReadOnly)
            if let error = editor.error {
                Section { Text(error.message).foregroundStyle(LumenColor.danger) }
            }
            if editor.isExisting && !editor.isReadOnly {
                Section {
                    Button("Delete event", role: .destructive) { confirmDelete = true }
                } footer: {
                    if editor.isSystemEvent && (editor.recurrence != nil || editor.showsStoredRecurrenceNote) {
                        Text("Deleting removes every occurrence of this event.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle(editor.isExisting ? "Event" : "New event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editor.isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await editor.save() { dismiss() } }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { if await editor.delete() { dismiss() } } }
        }
        .task { await editor.load() }
    }

    @ViewBuilder
    private var repeatRow: some View {
        if let note = editor.storedRecurrenceNote, editor.showsStoredRecurrenceNote {
            VStack(alignment: .leading, spacing: LumenSpace.xs) {
                Text("Repeat").lumenText(.body)
                Text(note).lumenText(.footnote).foregroundStyle(LumenColor.textSecondary)
                Button("Change repeat") { editor.replaceStoredRecurrence() }
                    .lumenText(.footnote)
            }
        } else {
            RecurrencePicker(rule: $editor.recurrence)
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        Section {
            if editor.isReadOnly {
                LabeledContent("Calendar", value: editor.systemCalendarTitle ?? "Calendar")
            } else {
                Picker("Calendar", selection: $editor.destination) {
                    if editor.offersLumenCalendars {
                        Section("Lumen") {
                            ForEach(editor.calendars) { calendar in
                                Text(calendar.name).tag(EventCalendarChoice?.some(.lumen(calendar.id)))
                            }
                        }
                    }
                    if editor.offersSystemCalendars {
                        Section("Your calendars") {
                            ForEach(editor.systemCalendars) { calendar in
                                Text(calendar.sourceName.isEmpty ? calendar.title : "\(calendar.title) · \(calendar.sourceName)")
                                    .tag(EventCalendarChoice?.some(.system(calendar.id)))
                            }
                        }
                    }
                }
                if editor.canRequestSystemAccess {
                    Button("Show my other calendars") { Task { await editor.requestSystemAccess() } }
                        .accessibilityHint("Asks for access to the calendars on this device, such as iCloud or Google.")
                }
            }
        } footer: {
            if editor.isReadOnly {
                Text("This event is in a calendar that can't be changed here.")
            } else if let explanation = editor.systemAccessExplanation {
                Text(explanation)
            } else if editor.isSystemEvent {
                Text("Saved in your calendar, not in Lumen. Changes apply to every occurrence.")
            }
        }
    }
}
