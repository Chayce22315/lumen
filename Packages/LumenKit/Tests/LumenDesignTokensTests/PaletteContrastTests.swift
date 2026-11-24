import Testing
import LumenDesignTokens

@Suite("Palette contrast (WCAG 2.x)")
struct PaletteContrastTests {
    func contrast(_ foreground: AdaptiveColor, on background: AdaptiveColor, _ appearance: Appearance) -> Double {
        let bg = background.value(for: appearance)
        let fg = foreground.value(for: appearance).composited(over: bg)
        return ColorValue.contrast(fg, bg)
    }

    @Test("contrast math matches WCAG reference values")
    func reference() {
        #expect(abs(ColorValue.contrast(ColorValue(hex: 0x000000), ColorValue(hex: 0xFFFFFF)) - 21) < 0.001)
        #expect(abs(ColorValue.contrast(ColorValue(hex: 0x777777), ColorValue(hex: 0xFFFFFF)) - 4.48) < 0.01)
        #expect(ColorValue.contrast(ColorValue(hex: 0x123456), ColorValue(hex: 0x123456)) == 1)
    }

    @Test("body text passes AA (4.5:1) on every surface in both appearances", arguments: Appearance.allCases)
    func bodyText(appearance: Appearance) {
        for surface in Palette.textSurfaces {
            for text in [Palette.textPrimary, Palette.textSecondary, Palette.accentText, Palette.success, Palette.warning, Palette.danger] {
                #expect(contrast(text, on: surface, appearance) >= 4.5, "\(text.value(for: appearance)) on \(surface.value(for: appearance))")
            }
        }
    }

    @Test("tertiary text and accent tint pass 3:1 (large text and UI components)", arguments: Appearance.allCases)
    func secondaryElements(appearance: Appearance) {
        for surface in Palette.textSurfaces {
            #expect(contrast(Palette.textTertiary, on: surface, appearance) >= 3)
            #expect(contrast(Palette.accent, on: surface, appearance) >= 3)
        }
    }

    @Test("button labels pass AA on the accent fill", arguments: Appearance.allCases)
    func buttons(appearance: Appearance) {
        #expect(contrast(Palette.onAccent, on: Palette.accentFill, appearance) >= 4.5)
    }

    @Test("identity colors are distinguishable from the surface", arguments: Appearance.allCases)
    func identity(appearance: Appearance) {
        for color in IdentityColor.allCases {
            #expect(contrast(color.color, on: Palette.surface, appearance) >= 3, "\(color)")
        }
    }

    @Test("separators stay subtle")
    func separators() {
        for appearance in Appearance.allCases {
            let ratio = contrast(Palette.separator, on: Palette.surface, appearance)
            #expect(ratio > 1.05 && ratio < 1.6)
        }
    }

    @Test("motion staggering is bounded")
    func motion() {
        #expect(Motion.staggerDelay(for: 0) == 0)
        #expect(Motion.staggerDelay(for: 3) == 3 * Motion.stagger)
        #expect(Motion.staggerDelay(for: 100) == Double(Motion.staggerLimit) * Motion.stagger)
        #expect(Motion.staggerDelay(for: -4) == 0)
    }
}
