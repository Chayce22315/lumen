import SwiftUI
import LumenDesignTokens
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    /// A color that follows the system appearance, built from a design token.
    public init(_ token: AdaptiveColor) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .light ? token.light : token.dark
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
        #else
        let value = token.dark
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
        #endif
    }
}

/// Lumen's semantic colors. Views use these names only — never literal colors.
public enum LumenColor {
    public static let background = Color(Palette.background)
    public static let surface = Color(Palette.surface)
    public static let surfaceElevated = Color(Palette.surfaceElevated)
    public static let surfaceHighlight = Color(Palette.surfaceHighlight)
    public static let separator = Color(Palette.separator)
    public static let border = Color(Palette.border)

    public static let textPrimary = Color(Palette.textPrimary)
    public static let textSecondary = Color(Palette.textSecondary)
    public static let textTertiary = Color(Palette.textTertiary)

    public static let accent = Color(Palette.accent)
    public static let accentText = Color(Palette.accentText)
    public static let accentFill = Color(Palette.accentFill)
    public static let onAccent = Color(Palette.onAccent)
    public static let accentSubtle = Color(Palette.accentSubtle)

    public static let success = Color(Palette.success)
    public static let warning = Color(Palette.warning)
    public static let danger = Color(Palette.danger)

    /// The identity color for a project or calendar color name.
    public static func identity(_ name: String) -> Color {
        Color((IdentityColor(rawValue: name) ?? .blue).color)
    }
}
