import SwiftUI
import LumenDesignTokens

extension Font {
    /// The font for a text role. Sizes follow Dynamic Type through the role's text style.
    public static func lumen(_ role: TextRole) -> Font {
        let style: Font.TextStyle
        switch role.textStyle {
        case "largeTitle": style = .largeTitle
        case "title2": style = .title2
        case "headline": style = .headline
        case "callout": style = .callout
        case "subheadline": style = .subheadline
        case "footnote": style = .footnote
        case "caption": style = .caption
        default: style = .body
        }
        let weight: Font.Weight
        switch role.weight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        return .system(style, design: role == .monospaced ? .monospaced : .default, weight: weight)
    }
}

private struct LumenTextModifier: ViewModifier {
    let role: TextRole

    func body(content: Content) -> some View {
        content
            .font(.lumen(role))
            .tracking(role.tracking)
            .lineSpacing(role.lineSpacing)
    }
}

extension View {
    /// Applies a text role: font, tracking and line spacing.
    public func lumenText(_ role: TextRole) -> some View {
        modifier(LumenTextModifier(role: role))
    }
}
