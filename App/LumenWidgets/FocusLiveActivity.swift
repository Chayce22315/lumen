import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import LumenWidgetData
import LumenDesignSystem

/// The focus session on the Lock Screen and in the Dynamic Island. The app starts, updates and
/// ends it (`LiveActivityFocusPresenter`); the countdown text and progress bar animate by
/// themselves from the content's dates, frozen while paused. Buttons run `LiveActivityIntent`s in
/// the app's process; tapping elsewhere opens the session's Focus screen.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreenView(state: context.state, sessionID: context.attributes.sessionID, isStale: context.isStale)
                .activityBackgroundTint(LumenColor.background)
                .activitySystemActionForegroundColor(LumenColor.accent)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FocusPhaseIcon(state: context.state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FocusCountdown(state: context.state)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title ?? "Focus")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        FocusProgressBar(state: context.state)
                        FocusControls(state: context.state, sessionID: context.attributes.sessionID)
                    }
                }
            } compactLeading: {
                FocusPhaseIcon(state: context.state)
            } compactTrailing: {
                FocusCountdown(state: context.state)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(maxWidth: 64)
            } minimal: {
                FocusPhaseIcon(state: context.state)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(LumenColor.accent)
        }
    }
}

/// The Lock Screen banner.
private struct FocusLockScreenView: View {
    let state: FocusActivityState
    let sessionID: UUID
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                FocusPhaseIcon(state: state)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title ?? "Focus")
                        .font(.headline)
                        .foregroundStyle(LumenColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(LumenColor.textSecondary)
                }
                Spacer(minLength: 8)
                FocusCountdown(state: state)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(LumenColor.textPrimary)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            if state.isActive {
                FocusProgressBar(state: state)
                FocusControls(state: state, sessionID: sessionID)
            }
        }
        .padding(16)
    }

    private var subtitle: String {
        switch state.phase {
        case .running: return isStale ? "Time's up" : "Focusing · \(state.plannedMinutes) min"
        case .paused: return "Paused"
        case .completed: return "Complete · \(state.focusedMinutes) min of focus"
        case .cancelled: return "Cancelled"
        }
    }
}

/// The time left: counting down while running, frozen while paused, a mark once ended.
private struct FocusCountdown: View {
    let state: FocusActivityState

    var body: some View {
        if state.isActive {
            Text(timerInterval: state.countdownRange, pauseTime: state.pausedAt, countsDown: true, showsHours: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(state.phase == .paused ? "Paused, time left" : "Time left")
        } else {
            Image(systemName: state.phase == .completed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(state.phase == .completed ? LumenColor.success : LumenColor.textSecondary)
                .accessibilityLabel(state.phase == .completed ? "Completed" : "Cancelled")
        }
    }
}

private struct FocusPhaseIcon: View {
    let state: FocusActivityState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state.phase {
        case .running: return "timer"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch state.phase {
        case .running: return LumenColor.accent
        case .paused: return LumenColor.warning
        case .completed: return LumenColor.success
        case .cancelled: return LumenColor.textSecondary
        }
    }
}

/// Fills as the session goes by; a paused session shows where it stopped.
private struct FocusProgressBar: View {
    let state: FocusActivityState

    var body: some View {
        Group {
            if let pausedAt = state.pausedAt {
                ProgressView(value: state.progress(at: pausedAt))
            } else {
                ProgressView(timerInterval: state.countdownRange, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            }
        }
        .progressViewStyle(.linear)
        .tint(state.phase == .paused ? LumenColor.warning : LumenColor.accent)
        .accessibilityHidden(true)
    }
}

/// Pause or resume, and finish. Each runs in the app's process through the focus service.
private struct FocusControls: View {
    let state: FocusActivityState
    let sessionID: UUID

    var body: some View {
        HStack(spacing: 8) {
            if state.phase == .paused {
                Button(intent: ResumeFocusIntent(sessionID: sessionID)) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(LumenColor.accent)
            } else {
                Button(intent: PauseFocusIntent(sessionID: sessionID)) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(LumenColor.warning)
            }
            Button(intent: FinishFocusIntent(sessionID: sessionID)) {
                Label("Finish", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .tint(LumenColor.success)
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }
}
