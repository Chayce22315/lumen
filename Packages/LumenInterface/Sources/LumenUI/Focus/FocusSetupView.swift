import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// Starting a focus session, from Home or a task. On start the sheet closes and `onOpen` shows
/// the session's Focus screen; while another session runs it offers that one instead.
struct FocusSetupView: View {
    let onOpen: (FocusSession) -> Void
    @State private var setup: FocusSetupViewModel
    @Environment(\.dismiss) private var dismiss

    init(taskID: TaskItem.ID?, services: LumenServices, onOpen: @escaping (FocusSession) -> Void) {
        self.onOpen = onOpen
        _setup = State(initialValue: FocusSetupViewModel(taskID: taskID, services: services))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let title = setup.taskTitle {
                    Section("Task") {
                        Label(title, systemImage: "checklist")
                            .lumenText(.body)
                    }
                }
                if let active = setup.activeSession {
                    Section {
                        Text("A focus session is already running. Finish or cancel it before starting another.")
                            .lumenText(.subheadline)
                            .foregroundStyle(LumenColor.textSecondary)
                        Button("Open the current session") {
                            dismiss()
                            onOpen(active)
                        }
                    }
                } else {
                    lengthSection
                    if setup.offersTaskCompletion {
                        Section {
                            Toggle("Complete the task when done", isOn: $setup.completesTask)
                        } footer: {
                            Text("Finishing early completes it too; cancelling doesn't.")
                        }
                    }
                }
                if let error = setup.error {
                    Section {
                        Text(error.message).foregroundStyle(LumenColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Start focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            guard let session = await setup.start() else { return }
                            dismiss()
                            onOpen(session)
                        }
                    }
                    .disabled(!setup.canStart)
                }
            }
            .task { await setup.load() }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(LumenRadius.sheet)
    }

    private var lengthSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LumenSpace.s) {
                    ForEach(setup.suggestedMinutes, id: \.self) { minutes in
                        Button("\(minutes) min") { setup.minutes = minutes }
                            .buttonStyle(LumenButtonStyle(minutes == setup.minutes ? .primary : .secondary))
                            .accessibilityLabel("\(minutes) minutes")
                            .accessibilityAddTraits(minutes == setup.minutes ? .isSelected : [])
                    }
                }
                .padding(.vertical, LumenSpace.xs)
            }
            Stepper(value: $setup.minutes, in: setup.minuteRange, step: 5) {
                LabeledContent("Length", value: setup.minutesLabel)
            }
        } header: {
            Text("Length")
        }
    }
}

/// The running or paused session on Home: what it is about and the time left; opens the Focus
/// screen.
struct ActiveFocusCard: View {
    let active: ActiveFocusViewModel
    let model: AppModel

    var body: some View {
        if let session = active.session, let range = active.countdownRange {
            Button {
                model.router.open(.entity(session.reference))
            } label: {
                HStack(spacing: LumenSpace.m) {
                    IconBadge(session.isPaused ? "pause.fill" : "timer", tint: session.isPaused ? LumenColor.warning : LumenColor.accent)
                    VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                        Text(active.title)
                            .lumenText(.headline)
                            .foregroundStyle(LumenColor.textPrimary)
                            .lineLimit(1)
                        Text(session.isPaused ? "Focus paused" : "Focusing")
                            .lumenText(.caption)
                            .foregroundStyle(LumenColor.textSecondary)
                    }
                    Spacer(minLength: LumenSpace.s)
                    Text(timerInterval: range, pauseTime: session.pausedAt, countsDown: true, showsHours: true)
                        .lumenText(.headline)
                        .monospacedDigit()
                        .foregroundStyle(LumenColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                }
                .lumenSurface(padding: LumenSpace.m)
            }
            .buttonStyle(.pressable)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the focus timer")
        }
    }
}
