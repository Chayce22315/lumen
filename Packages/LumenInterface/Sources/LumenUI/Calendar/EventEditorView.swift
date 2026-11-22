import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Creating or editing a Lumen event.
struct EventEditorView: View {
    @State private var editor: EventEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(services: LumenServices, eventID: CalendarEvent.ID?, day: CalendarDate? = nil) {
        _editor = State(initialValue: EventEditorViewModel(services: services, eventID: eventID, day: day))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $editor.title)
                TextField("Location", text: $editor.location)
            }
            Section {
                Toggle("All day", isOn: $editor.isAllDay)
                DatePicker("Starts", selection: $editor.start, displayedComponents: editor.isAllDay ? .date : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $editor.end, in: editor.start..., displayedComponents: editor.isAllDay ? .date : [.date, .hourAndMinute])
                RecurrencePicker(rule: $editor.recurrence)
            }
            Section {
                Picker("Calendar", selection: $editor.calendarID) {
                    ForEach(editor.calendars) { calendar in
                        Text(calendar.name).tag(LumenCalendar.ID?.some(calendar.id))
                    }
                }
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
            }
            Section {
                TextField("Notes", text: $editor.notes, axis: .vertical).lineLimit(3...10)
            }
            if let error = editor.error {
                Section { Text(error.message).foregroundStyle(LumenColor.danger) }
            }
            if editor.eventID != nil {
                Section {
                    Button("Delete event", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle(editor.eventID == nil ? "New event" : "Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { if await editor.save() != nil { dismiss() } }
                }
                .disabled(!editor.canSave)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { if await editor.delete() { dismiss() } } }
        }
        .task { await editor.load() }
    }
}
