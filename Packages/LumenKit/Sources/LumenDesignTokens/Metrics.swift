/// 4-point spacing scale. Layouts use these values only.
public enum Spacing {
    public static let xxs: Double = 2
    public static let xs: Double = 4
    public static let s: Double = 8
    public static let m: Double = 12
    public static let l: Double = 16
    public static let xl: Double = 24
    public static let xxl: Double = 32
    public static let xxxl: Double = 48

    /// Horizontal inset of screen content.
    public static let screenInset: Double = 20
}

/// Corner radii. Lumen uses few rounded containers; most content sits on flat grouped surfaces.
public enum Radius {
    public static let small: Double = 6
    public static let medium: Double = 10
    public static let large: Double = 14
    public static let sheet: Double = 22
}

public enum Stroke {
    /// One physical pixel on 2× and 3× displays is drawn as 0.5 pt.
    public static let hairline: Double = 0.5
    public static let regular: Double = 1
    public static let focus: Double = 2
}

public enum Layout {
    /// Comfortable reading measure for long text.
    public static let readableWidth: Double = 640
    /// Minimum touch target (Human Interface Guidelines).
    public static let minimumTapTarget: Double = 44
    public static let iconSmall: Double = 14
    public static let iconRegular: Double = 17
    public static let iconLarge: Double = 22
    public static let rowMinimumHeight: Double = 48
}
