import SwiftUI
import LumenDesignTokens

/// CGFloat views of the spacing, radius and layout tokens.
public enum LumenSpace {
    public static let xxs = CGFloat(Spacing.xxs)
    public static let xs = CGFloat(Spacing.xs)
    public static let s = CGFloat(Spacing.s)
    public static let m = CGFloat(Spacing.m)
    public static let l = CGFloat(Spacing.l)
    public static let xl = CGFloat(Spacing.xl)
    public static let xxl = CGFloat(Spacing.xxl)
    public static let xxxl = CGFloat(Spacing.xxxl)
    public static let screen = CGFloat(Spacing.screenInset)
}

public enum LumenRadius {
    public static let small = CGFloat(Radius.small)
    public static let medium = CGFloat(Radius.medium)
    public static let large = CGFloat(Radius.large)
    public static let sheet = CGFloat(Radius.sheet)
}

public enum LumenLayout {
    public static let hairline = CGFloat(Stroke.hairline)
    public static let readableWidth = CGFloat(Layout.readableWidth)
    public static let tapTarget = CGFloat(Layout.minimumTapTarget)
    public static let rowHeight = CGFloat(Layout.rowMinimumHeight)
}
