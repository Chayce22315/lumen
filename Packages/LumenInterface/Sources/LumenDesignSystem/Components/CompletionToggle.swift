import SwiftUI

/// The round checkbox of a task row. The symbol morphs between states and confirms with a light
/// haptic; the hit area is a full 44 pt square.
public struct CompletionToggle: View {
    let isComplete: Bool
    let tint: Color
    let label: String
    let action: () -> Void

    public init(isComplete: Bool, tint: Color = LumenColor.accent, label: String, action: @escaping () -> Void) {
        self.isComplete = isComplete
        self.tint = tint
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isComplete ? tint : LumenColor.textTertiary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: isComplete) { _, new in new }
        .accessibilityLabel(label)
        .accessibilityValue(isComplete ? "Completed" : "Not completed")
        .accessibilityAddTraits(.isButton)
    }
}
