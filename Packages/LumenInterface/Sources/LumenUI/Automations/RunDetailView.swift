import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenAutomation

/// One run of an automation, step by step: what started it, what each step received and
/// produced, how long it took, retries and errors. It can be run again or stopped.
struct RunDetailView: View {
    @State private var model: RunDetailViewModel

    init(services: LumenServices, runID: WorkflowRun.ID) {
        _model = State(initialValue: RunDetailViewModel(services: services, runID: runID))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.canCancel {
                        Button { Task { await model.cancel() } } label: { Label("Stop", systemImage: "stop.circle") }
                    }
                    if model.state.value != nil {
                        Button { Task { await model.rerun() } } label: {
                            if model.isRerunning {
                                ProgressView()
                            } else {
                                Label("Run again", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isRerunning)
                        .accessibilityLabel("Run again with the same trigger and input")
                    }
                }
            }
            .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
        case .loaded(let detail):
            List {
                Section { RunHeader(detail: detail) }
                if let rerun = model.latestRerun {
                    Section {
                        NavigationLink(value: AppDestination.entity(rerun.reference)) {
                            RunSummaryRow(run: rerun, workflowName: "The new run")
                        }
                    } footer: {
                        Text("It used the automation as it is now, with this run's trigger and input.")
                    }
                }
                Section("Steps") {
                    if detail.steps.isEmpty {
                        Text("No steps ran.").foregroundStyle(LumenColor.textSecondary)
                    }
                    ForEach(detail.steps) { step in
                        StepCard(step: step, number: (detail.steps.firstIndex(of: step) ?? 0) + 1)
                    }
                }
                Section("Started by") {
                    KeyValueLines(lines: detail.trigger)
                }
                if !detail.input.isEmpty {
                    Section("Input") {
                        KeyValueLines(lines: detail.input)
                    }
                }
            }
        }
    }
}

private struct RunHeader: View {
    let detail: RunDetailViewModel.Detail

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            HStack(spacing: LumenSpace.s) {
                Image(systemName: WorkflowStyle.symbol(detail.run.status))
                    .foregroundStyle(WorkflowStyle.tint(detail.run.status))
                Text(WorkflowStyle.title(detail.run.status))
                    .lumenText(.headline)
                if detail.isRerun {
                    Chip("Run again", symbolName: "arrow.clockwise")
                }
            }
            Text(detail.workflowName).lumenText(.body)
            Text(timing).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
            if let resumeAt = detail.run.resumeAt, detail.run.status == .waiting {
                Text("Continues \(resumeAt.formatted(date: .abbreviated, time: .shortened))")
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
            }
            if let error = detail.run.errorMessage {
                Text(error).lumenText(.callout).foregroundStyle(LumenColor.danger)
            }
        }
        .padding(.vertical, LumenSpace.xs)
        .accessibilityElement(children: .combine)
    }

    private var timing: String {
        var parts = ["Started " + detail.run.startedAt.formatted(date: .abbreviated, time: .standard)]
        if let duration = detail.duration {
            parts.append("took " + WorkflowStyle.duration(duration))
        }
        return parts.joined(separator: ", ")
    }
}

private struct StepCard: View {
    let step: RunDetailViewModel.StepRow
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            HStack(spacing: LumenSpace.m) {
                IconBadge(WorkflowStyle.symbol(step.kind), tint: WorkflowStyle.tint(step.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(number). \(step.title)").lumenText(.body)
                    Text(timing).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                }
                Spacer(minLength: 0)
                Label(WorkflowStyle.title(step.status), systemImage: WorkflowStyle.symbol(step.status))
                    .labelStyle(.iconOnly)
                    .foregroundStyle(WorkflowStyle.tint(step.status))
                    .accessibilityLabel(WorkflowStyle.title(step.status))
            }
            if let branch = step.branch {
                Text(branch).lumenText(.callout).foregroundStyle(LumenColor.textSecondary)
            }
            if let message = step.message {
                Text(message).lumenText(.callout)
            }
            if let error = step.errorMessage {
                Text(error).lumenText(.callout).foregroundStyle(LumenColor.danger)
            }
            ForEach(step.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.warning)
            }
            if !step.inputs.isEmpty {
                DisclosureGroup("Inputs") { KeyValueLines(lines: step.inputs) }
                    .lumenText(.subheadline)
            }
            if !step.output.isEmpty {
                DisclosureGroup("Output") { KeyValueLines(lines: step.output) }
                    .lumenText(.subheadline)
            }
        }
        .padding(.vertical, LumenSpace.xs)
    }

    private var timing: String {
        var parts = [step.startedAt.formatted(date: .omitted, time: .standard)]
        if let duration = step.duration {
            parts.append(WorkflowStyle.duration(duration))
        }
        if step.retries > 0 {
            parts.append(step.retries == 1 ? "retried once" : "retried \(step.retries) times")
        }
        return parts.joined(separator: " · ")
    }
}

/// `path   value` lines from run history; values can be selected and copied.
private struct KeyValueLines: View {
    let lines: [JSONPreview.Line]

    var body: some View {
        ForEach(lines) { line in
            HStack(alignment: .firstTextBaseline, spacing: LumenSpace.m) {
                Text(line.path)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                    .frame(maxWidth: 140, alignment: .leading)
                Text(line.value)
                    .lumenText(.monospaced)
                    .foregroundStyle(LumenColor.textPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
