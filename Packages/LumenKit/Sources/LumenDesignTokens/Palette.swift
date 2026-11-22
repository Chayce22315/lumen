/// A color with a value for each appearance.
public struct AdaptiveColor: Sendable, Hashable {
    public let dark: ColorValue
    public let light: ColorValue

    public init(dark: ColorValue, light: ColorValue) {
        self.dark = dark
        self.light = light
    }

    public func value(for appearance: Appearance) -> ColorValue {
        appearance == .dark ? dark : light
    }
}

public enum Appearance: String, Sendable, Hashable, CaseIterable {
    case dark
    case light
}

/// Lumen's semantic palette. Dark-first: the dark values are the design; light values are
/// derived to keep the same hierarchy and contrast. Every text/background pairing is verified
/// against WCAG 2.x in `PaletteContrastTests`.
public enum Palette {
    // MARK: Surfaces

    /// The canvas behind everything.
    public static let background = AdaptiveColor(dark: ColorValue(hex: 0x101827), light: ColorValue(hex: 0xF5F7FB))
    /// Grouped content: lists, panels, the tab bar.
    public static let surface = AdaptiveColor(dark: ColorValue(hex: 0x182438), light: ColorValue(hex: 0xFFFFFF))
    /// Content lifted above a surface: sheets, menus, the command palette.
    public static let surfaceElevated = AdaptiveColor(dark: ColorValue(hex: 0x1F2D45), light: ColorValue(hex: 0xFFFFFF))
    /// Pressed or selected rows.
    public static let surfaceHighlight = AdaptiveColor(dark: ColorValue(hex: 0x263652), light: ColorValue(hex: 0xE9EEF7))
    /// Hairline separators and borders.
    public static let separator = AdaptiveColor(dark: ColorValue(hex: 0xFFFFFF, alpha: 0.08), light: ColorValue(hex: 0x0F172A, alpha: 0.10))
    /// Stronger borders for focused fields.
    public static let border = AdaptiveColor(dark: ColorValue(hex: 0xFFFFFF, alpha: 0.14), light: ColorValue(hex: 0x0F172A, alpha: 0.16))

    // MARK: Text

    public static let textPrimary = AdaptiveColor(dark: ColorValue(hex: 0xFFFFFF), light: ColorValue(hex: 0x0F172A))
    public static let textSecondary = AdaptiveColor(dark: ColorValue(hex: 0xA5B2C8), light: ColorValue(hex: 0x4A5568))
    /// Metadata, placeholders and disabled labels.
    public static let textTertiary = AdaptiveColor(dark: ColorValue(hex: 0x7C8AA3), light: ColorValue(hex: 0x6B768A))

    // MARK: Accent

    /// The brand tint: icons, selection, progress, focus rings.
    public static let accent = AdaptiveColor(dark: ColorValue(hex: 0x397BFF), light: ColorValue(hex: 0x2563EB))
    /// Accent used for text and links, tuned to stay readable on every surface.
    public static let accentText = AdaptiveColor(dark: ColorValue(hex: 0x6A9CFF), light: ColorValue(hex: 0x1F5BD8))
    /// Fill of primary buttons; `onAccent` text on it passes 4.5:1.
    public static let accentFill = AdaptiveColor(dark: ColorValue(hex: 0x2A69EC), light: ColorValue(hex: 0x2563EB))
    public static let onAccent = AdaptiveColor(dark: ColorValue(hex: 0xFFFFFF), light: ColorValue(hex: 0xFFFFFF))
    /// Low-emphasis accent wash behind selected chips and rows.
    public static let accentSubtle = AdaptiveColor(dark: ColorValue(hex: 0x397BFF, alpha: 0.16), light: ColorValue(hex: 0x2563EB, alpha: 0.10))

    // MARK: Status

    public static let success = AdaptiveColor(dark: ColorValue(hex: 0x3CCB91), light: ColorValue(hex: 0x0E7F56))
    public static let warning = AdaptiveColor(dark: ColorValue(hex: 0xF2B84B), light: ColorValue(hex: 0x9A6406))
    public static let danger = AdaptiveColor(dark: ColorValue(hex: 0xF26B76), light: ColorValue(hex: 0xC9293A))

    /// Every opaque surface text may sit on.
    public static let textSurfaces: [AdaptiveColor] = [background, surface, surfaceElevated]
}

/// Identity colors for projects and calendars, muted so they never compete with the accent.
public enum IdentityColor: String, Sendable, Hashable, CaseIterable {
    case blue, indigo, teal, green, amber, orange, rose, slate

    public var color: AdaptiveColor {
        switch self {
        case .blue: return AdaptiveColor(dark: ColorValue(hex: 0x5C93FF), light: ColorValue(hex: 0x2563EB))
        case .indigo: return AdaptiveColor(dark: ColorValue(hex: 0x8B8CF8), light: ColorValue(hex: 0x4F46E5))
        case .teal: return AdaptiveColor(dark: ColorValue(hex: 0x3CC4C4), light: ColorValue(hex: 0x0F766E))
        case .green: return AdaptiveColor(dark: ColorValue(hex: 0x4CC98A), light: ColorValue(hex: 0x15803D))
        case .amber: return AdaptiveColor(dark: ColorValue(hex: 0xEDB65A), light: ColorValue(hex: 0x92600A))
        case .orange: return AdaptiveColor(dark: ColorValue(hex: 0xF28F5C), light: ColorValue(hex: 0xC2410C))
        case .rose: return AdaptiveColor(dark: ColorValue(hex: 0xF07A98), light: ColorValue(hex: 0xBE185D))
        case .slate: return AdaptiveColor(dark: ColorValue(hex: 0x9AA6BC), light: ColorValue(hex: 0x475569))
        }
    }
}
