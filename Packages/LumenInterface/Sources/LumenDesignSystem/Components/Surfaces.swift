import SwiftUI

private struct SurfaceModifier: ViewModifier {
    let padding: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(elevated ? LumenColor.surfaceElevated : LumenColor.surface, in: RoundedRectangle(cornerRadius: LumenRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LumenRadius.large, style: .continuous)
                    .strokeBorder(LumenColor.separator, lineWidth: LumenLayout.hairline)
            )
    }
}

extension View {
    /// Places content on a grouped surface with a hairline border. Used for dashboard widgets and
    /// grouped controls; plain lists don't need it.
    public func lumenSurface(padding: CGFloat = LumenSpace.l, elevated: Bool = false) -> some View {
        modifier(SurfaceModifier(padding: padding, elevated: elevated))
    }

    /// The app background behind scrolling content.
    public func lumenScreenBackground() -> some View {
        background(LumenColor.background.ignoresSafeArea())
    }
}

/// A full-width hairline.
public struct HairlineDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(LumenColor.separator)
            .frame(height: LumenLayout.hairline)
            .accessibilityHidden(true)
    }
}

/// A section title with an optional trailing action.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .lumenText(.footnote)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(LumenColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LumenSpace.s)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
