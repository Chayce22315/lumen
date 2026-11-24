import SwiftUI

/// A compact label for tags, dates and parsed capture fields.
public struct Chip: View {
    let text: String
    let symbolName: String?
    let tint: Color
    let isProminent: Bool

    public init(_ text: String, symbolName: String? = nil, tint: Color = LumenColor.textSecondary, isProminent: Bool = false) {
        self.text = text
        self.symbolName = symbolName
        self.tint = tint
        self.isProminent = isProminent
    }

    public var body: some View {
        HStack(spacing: LumenSpace.xs) {
            if let symbolName {
                Image(systemName: symbolName)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
        }
        .lumenText(.caption)
        .foregroundStyle(isProminent ? LumenColor.accentText : tint)
        .padding(.horizontal, LumenSpace.s)
        .padding(.vertical, LumenSpace.xxs + 1)
        .background(isProminent ? LumenColor.accentSubtle : LumenColor.surfaceHighlight.opacity(0.6), in: Capsule())
    }
}

/// A small symbol in a tinted rounded square, used as a row's leading icon.
public struct IconBadge: View {
    let symbolName: String
    let tint: Color

    public init(_ symbolName: String, tint: Color = LumenColor.accent) {
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: LumenRadius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}
