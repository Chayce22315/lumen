import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// Picks a note or document to send with the next assistant message.
struct AttachmentPickerView: View {
    let alreadyAttached: Set<EntityReference>
    let onPick: (AttachmentCandidate) -> Void
    @State private var picker: AttachmentPickerViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, alreadyAttached: Set<EntityReference>, onPick: @escaping (AttachmentCandidate) -> Void) {
        self.alreadyAttached = alreadyAttached
        self.onPick = onPick
        _picker = State(initialValue: AttachmentPickerViewModel(services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Attach from library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $picker.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Notes and documents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await picker.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch picker.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle", actionTitle: "Try again") {
                Task { await picker.load() }
            }
        case .loaded(let items) where items.isEmpty:
            if picker.query.nonBlank == nil {
                StateMessage(
                    "Nothing to attach yet",
                    message: "Notes with text, and documents Lumen can read, can be sent to the assistant.",
                    symbolName: "paperclip"
                )
            } else {
                ContentUnavailableView.search(text: picker.query)
            }
        case .loaded(let items):
            List(items) { item in
                let attached = alreadyAttached.contains(item.reference)
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    HStack(spacing: LumenSpace.m) {
                        IconBadge(item.symbolName)
                        VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                            Text(item.title).lumenText(.body).foregroundStyle(LumenColor.textPrimary).lineLimit(1)
                            Text(item.detail).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                        }
                        Spacer(minLength: LumenSpace.s)
                        if attached {
                            Image(systemName: "checkmark").foregroundStyle(LumenColor.accent)
                        }
                    }
                }
                .disabled(attached)
                .listRowBackground(LumenColor.surface)
                .accessibilityValue(attached ? "Attached" : "")
            }
        }
    }
}
