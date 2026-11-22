/// Text roles. Each maps to a Dynamic Type text style so sizes scale with the user's setting;
/// `size` is the default (Large) size, used for layout math and previews.
public enum TextRole: String, Sendable, Hashable, CaseIterable {
    case display
    case title
    case headline
    case body
    case bodyEmphasized
    case callout
    case subheadline
    case footnote
    case caption
    case monospaced

    public enum Weight: String, Sendable, Hashable {
        case regular, medium, semibold, bold
    }

    /// The system text style the role scales with (SwiftUI `Font.TextStyle` names).
    public var textStyle: String {
        switch self {
        case .display: return "largeTitle"
        case .title: return "title2"
        case .headline: return "headline"
        case .body, .bodyEmphasized, .monospaced: return "body"
        case .callout: return "callout"
        case .subheadline: return "subheadline"
        case .footnote: return "footnote"
        case .caption: return "caption"
        }
    }

    public var size: Double {
        switch self {
        case .display: return 32
        case .title: return 22
        case .headline: return 17
        case .body, .bodyEmphasized: return 17
        case .monospaced: return 15
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        }
    }

    public var weight: Weight {
        switch self {
        case .display: return .bold
        case .title, .headline, .bodyEmphasized: return .semibold
        case .body, .callout, .subheadline, .footnote, .caption, .monospaced: return .regular
        }
    }

    /// Letter spacing in points; large text is tightened slightly.
    public var tracking: Double {
        switch self {
        case .display: return -0.6
        case .title: return -0.3
        case .caption: return 0.2
        default: return 0
        }
    }

    /// Extra space between lines in points.
    public var lineSpacing: Double {
        switch self {
        case .body, .callout: return 3
        case .subheadline, .footnote: return 2
        default: return 0
        }
    }
}
