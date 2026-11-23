import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// One focus session: a large countdown with pause, resume and finish while it runs, its summary
/// once it ended. The countdown text and the ring are driven by the session's timestamps, so the
/// screen is right whenever it is opened (from Home, a task, the Live Activity or a notification).
struct FocusView: View {
    let services: LumenServices
    let model: AppModel
    @State private var focus: FocusViewModel
    @State private var confirmCancel = false
    @Environment(\.dismiss) private var dismiss

    init(sessionID: FocusSession.ID, services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _focus = State(initialValue: FocusViewModel(sessionID: sessionID, services: services))
    }

    var body: some View {
        Group {
            switch focus.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
            case .loaded(let session):
                content(session)
            }
        }
        .lumenScreenBackground()
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.inline)
        .task { await focus.start() }
        .confirmationDialog("Cancel this session?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel session", role: .destructive) { Task { await focus.cancel() } }
            Button("Keep focusing", role: .cancel) {}
        } message: {
            Text("The time so far won't count as focus.")
        }
    }

    private func content(_ session: FocusSession) -> some View {
        ScrollView {
            VStack(spacing: LumenSpace.xl) {
                VStack(spacing: LumenSpace.xs) {
                    Text(focus.title)
                        .lumenText(.title)
                        .foregroundStyle(LumenColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(phaseLabel(session))
                        .lumenText(.subheadline)
                        .foregroundStyle(LumenColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                FocusDial(focus: focus, session: session, now: { services.timeSource.now() })

                if let summary = focus.summary {
                    Text(summary)
                        .lumenText(.callout)
                        .foregroundStyle(LumenColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                if let error = focus.error {
                    Text(error.message)
                        .lumenText(.footnote)
                        .foregroundStyle(LumenColor.danger)
                        .multilineTextAlignment(.center)
                }
                controls(session)
            }
            .padding(LumenSpace.screen)
            .frame(maxWidth: LumenLayout.readableWidth)
            .frame(maxWidth: .infinity)
            .lumenAnimation(.lumenSmooth, value: session.phase)
        }
    }

    private func phaseLabel(_ session: FocusSession) -> String {
        switch session.phase {
        case .running: return "Focusing · \(session.plannedMinutes) min session"
        case .paused: return "Paused"
        case .completed: return "Session complete"
        case .cancelled: return "Session cancelled"
        }
    }

    @ViewBuilder
    private func controls(_ session: FocusSession) -> some View {
        VStack(spacing: LumenSpace.m) {
            switch session.phase {
            case .running:
                HStack(spacing: LumenSpace.m) {
                    Button { Task { await focus.pause() } } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lumenSecondary)
                    finishButton
                }
                cancelButton
            case .paused:
                HStack(spacing: LumenSpace.m) {
                    Button { Task { await focus.resume() } } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lumenPrimary)
                    Button { Task { await focus.finish() } } label: {
                        Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lumenSecondary)
                }
                cancelButton
            case .completed, .cancelled:
                if let taskID = session.taskID, focus.taskTitle != nil {
                    Button {
                        model.router.open(.entity(EntityReference(kind: .task, id: taskID)))
                    } label: {
                        Label("Open task", systemImage: "checklist").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lumenSecondary)
                }
                Button { dismiss() } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.lumenPrimary)
            }
        }
        .disabled(focus.isWorking)
    }

    private var finishButton: some View {
        Button { Task { await focus.finish() } } label: {
            Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
        }
        .buttonStyle(.lumenPrimary)
        .accessibilityHint("Ends the session now and counts the time so far")
    }

    private var cancelButton: some View {
        Button("Cancel session", role: .destructive) { confirmCancel = true }
            .buttonStyle(.lumenQuiet)
            .accessibilityHint("Ends the session without counting it")
    }
}

/// The ring and the large countdown. The ring advances once a second from the session's
/// timestamps; with Reduce Motion it steps without animating and the running glow stays still.
private struct FocusDial: View {
    let focus: FocusViewModel
    let session: FocusSession
    let now: () -> Date
    @ScaledMetric(relativeTo: .largeTitle) private var digitSize: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        TimelineView(.periodic(from: now(), by: 1)) { context in
            let progress = focus.progress(at: context.date)
            ZStack {
                Circle()
                    .stroke(LumenColor.separator, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
                Circle()
                    .fill(tint.opacity(0.08))
                    .padding(24)
                    .scaleEffect(breathing && !reduceMotion ? 1.04 : 1)
                centre
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus timer")
            .accessibilityValue(focus.status(at: context.date))
        }
        .frame(maxWidth: 300)
        .aspectRatio(1, contentMode: .fit)
        .padding(.vertical, LumenSpace.m)
        .onAppear(perform: updateBreathing)
        .onChange(of: session.phase) { _, _ in updateBreathing() }
    }

    @ViewBuilder
    private var centre: some View {
        if session.isActive, let range = focus.countdownRange {
            Text(timerInterval: range, pauseTime: focus.pausedAt, countsDown: true, showsHours: true)
                .font(.system(size: digitSize, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.isPaused ? LumenColor.textSecondary : LumenColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 36)
        } else {
            Image(systemName: session.phase == .completed ? "checkmark" : "xmark")
                .font(.system(size: digitSize * 0.75, weight: .light))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch session.phase {
        case .running: return LumenColor.accent
        case .paused: return LumenColor.warning
        case .completed: return LumenColor.success
        case .cancelled: return LumenColor.textTertiary
        }
    }

    private func updateBreathing() {
        guard !reduceMotion, session.phase == .running else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
    }
}
