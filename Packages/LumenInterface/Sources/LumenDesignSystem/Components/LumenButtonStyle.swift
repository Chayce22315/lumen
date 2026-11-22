import SwiftUI
import LumenDesignTokens

/// Lumen's buttons: one filled primary per screen, quiet everything else.
public struct LumenButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        case primary
        case secondary
        case quiet
        case destructive
    }

    public let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ kind: Kind = .primary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lumenText(.bodyEmphasized)
            .padding(.horizontal, LumenSpace.l)
            .padding(.vertical, LumenSpace.m)
            .frame(minHeight: LumenLayout.tapTarget)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: LumenRadius.medium, style: .continuous)
                        .strokeBorder(LumenColor.border, lineWidth: LumenLayout.hairline)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressedScale : 1)
            .animation(.lumenSnappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return LumenColor.onAccent
        case .secondary: return LumenColor.textPrimary
        case .quiet: return LumenColor.accentText
        case .destructive: return LumenColor.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return LumenColor.accentFill
        case .secondary: return LumenColor.surface
        case .quiet, .destructive: return .clear
        }
    }
}

extension ButtonStyle where Self == LumenButtonStyle {
    public static var lumenPrimary: LumenButtonStyle { LumenButtonStyle(.primary) }
    public static var lumenSecondary: LumenButtonStyle { LumenButtonStyle(.secondary) }
    public static var lumenQuiet: LumenButtonStyle { LumenButtonStyle(.quiet) }
    public static var lumenDestructive: LumenButtonStyle { LumenButtonStyle(.destructive) }
}

/// Press feedback for custom tappable rows and tiles.
public struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressedScale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.lumenSnappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    public static var pressable: PressableStyle { PressableStyle() }
}
