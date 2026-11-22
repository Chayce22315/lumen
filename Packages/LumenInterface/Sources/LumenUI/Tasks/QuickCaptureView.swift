import SwiftUI
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// Natural-language capture: type a line, see what Lumen understood, add it.
struct QuickCaptureView: View {
    @State private var capture: QuickCaptureViewModel
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, initialText: String?) {
        _capture = State(initialValue: QuickCaptureViewModel(services: services, initialText: initialText))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.l) {
            Text("New task")
                .lumenText(.headline)
                .foregroundStyle(LumenColor.textSecondary)
            TextField("Call Sam tomorrow at 5pm !high #family", text: $capture.text, axis: .vertical)
                .lumenText(.body)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { Task { await submit() } }
                .padding(LumenSpace.m)
                .background(LumenColor.surface, in: RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous))
                .accessibilityLabel("Task")
                .accessibilityHint("Type a title. Dates, times, priorities like !high, #tags and +project are recognised.")
            chips
            if let error = capture.error {
                Text(error.message).lumenText(.footnote).foregroundStyle(LumenColor.danger)
            }
            HStack {
                if let created = capture.lastCreated {
                    Label("Added “\(created.title)”", systemImage: "checkmark")
                        .lumenText(.footnote)
                        .foregroundStyle(LumenColor.success)
                        .transition(.opacity)
                }
                Spacer()
                Button("Add") { Task { await submit() } }
                    .buttonStyle(.lumenPrimary)
                    .disabled(!capture.canSubmit)
            }
        }
        .padding(LumenSpace.screen)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LumenColor.surfaceElevated.ignoresSafeArea())
        .onAppear { isFocused = true }
        .animation(.lumenSnappy, value: capture.chips)
        .sensoryFeedback(.success, trigger: capture.lastCreated?.id)
    }

    @ViewBuilder
    private var chips: some View {
        if !capture.chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LumenSpace.s) {
                    ForEach(capture.chips) { chip in
                        Chip(chip.label, symbolName: chip.symbolName, isProminent: true)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Understood: " + capture.chips.map(\.label).joined(separator: ", "))
        }
    }

    private func submit() async {
        if await capture.submit() != nil {
            isFocused = true
        }
    }
}
