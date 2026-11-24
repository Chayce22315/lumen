import Foundation

/// A key combination, described without SwiftUI so the assignments can be tested.
public struct CommandShortcut: Sendable, Hashable {
    public enum Modifier: Sendable, Hashable, CaseIterable {
        case command, shift, option, control
    }

    public let key: Character
    public let modifiers: Set<Modifier>

    public init(_ key: Character, _ modifiers: Set<Modifier> = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// The app's menu commands. The scene lists them in the menu bar and in iPad's ⌘-hold shortcut
/// overlay; performing one goes through `AppModel.perform(_:)` to the router.
public enum AppCommand: Sendable, Hashable, Identifiable {
    case commandPalette
    case quickCapture
    case newNote
    case find
    case settings
    /// ⌘1…⌘5 switch between the tab bar's sections (the sidebar's groups on iPad).
    case showSection(AppTab)

    /// Every command, in menu order.
    public static var all: [AppCommand] {
        [.quickCapture, .newNote, .commandPalette, .find, .settings] + AppTab.allCases.map(AppCommand.showSection)
    }

    public var id: String {
        switch self {
        case .commandPalette: return "commandPalette"
        case .quickCapture: return "quickCapture"
        case .newNote: return "newNote"
        case .find: return "find"
        case .settings: return "settings"
        case .showSection(let tab): return "showSection.\(tab.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .commandPalette: return "Command Palette"
        case .quickCapture: return "New Task"
        case .newNote: return "New Note"
        case .find: return "Find"
        case .settings: return "Settings"
        case .showSection(let tab): return tab.title
        }
    }

    public var shortcut: CommandShortcut {
        switch self {
        case .commandPalette: return CommandShortcut("k")
        case .quickCapture: return CommandShortcut("n")
        case .newNote: return CommandShortcut("n", [.command, .shift])
        case .find: return CommandShortcut("f")
        case .settings: return CommandShortcut(",")
        case .showSection(let tab):
            let position = (AppTab.allCases.firstIndex(of: tab) ?? 0) + 1
            // Five tabs, so the position is always a single digit.
            return CommandShortcut(Character(String(position)))
        }
    }
}
