import SwiftUI
import LumenDesignTokens

/// Placeholder rows shown while content loads, shimmering unless Reduce Motion is on.
public struct SkeletonRows: View {
    let count: Int
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int = 4) {
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.l) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: LumenSpace.m) {
                    Circle().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: LumenSpace.xs) {
                        RoundedRectangle(cornerRadius: 4).frame(width: index.isMultiple(of: 2) ? 180 : 140, height: 12)
                        RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 10).opacity(0.6)
                    }
                }
            }
        }
        .foregroundStyle(LumenColor.surfaceHighlight)
        .overlay {
            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, LumenColor.textPrimary.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width / 2)
                        .offset(x: phase * proxy.size.width)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// An honest empty or error state with an optional action.
public struct StateMessage: View {
    let title: String
    let message: String
    let symbolName: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ title: String, message: String, symbolName: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
                .foregroundStyle(LumenColor.textPrimary)
        } description: {
            Text(message).foregroundStyle(LumenColor.textSecondary)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.lumenSecondary)
            }
        }
    }
}

/// A non-blocking message at the top of the screen.
public struct Banner: View {
    let title: String
    let message: String
    let tint: Color
    let onDismiss: () -> Void

    public init(title: String, message: String, tint: Color = LumenColor.danger, onDismiss: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.tint = tint
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: LumenSpace.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                Text(title).lumenText(.headline).foregroundStyle(LumenColor.textPrimary)
                Text(message).lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumenColor.textTertiary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .lumenSurface(padding: LumenSpace.m, elevated: true)
        .accessibilityElement(children: .combine)
    }
}

/// A short confirmation capsule.
public struct Toast: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .lumenText(.subheadline)
            .foregroundStyle(LumenColor.textPrimary)
            .padding(.horizontal, LumenSpace.l)
            .padding(.vertical, LumenSpace.m)
            .background(LumenColor.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(LumenColor.separator, lineWidth: LumenLayout.hairline))
            .accessibilityAddTraits(.isStaticText)
    }
}
