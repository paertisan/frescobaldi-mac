import AppKit
import FrescobaldiCore
import SwiftUI

/// The color theme for the whole window: the editor and its syntax colors,
/// plus the toolbar, sidebar, issues panel and the area around the PDF.
/// Dark themes also give the window a dark appearance, so standard
/// controls match. "System" uses the system colors, which follow light and
/// dark mode and Increase Contrast.
struct EditorTheme {
    enum Name: String, CaseIterable, Identifiable {
        case everforest, nord, catppuccinFrappe, monokai, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everforest: "Everforest"
            case .nord: "Nord"
            case .catppuccinFrappe: "Catppuccin Frappé"
            case .monokai: "Monokai"
            case .system: "System"
            }
        }
    }

    let name: Name
    let background: NSColor
    let foreground: NSColor
    let insertionPoint: NSColor
    let selection: NSColor
    /// Background of the line with the insertion point, if highlighted.
    let currentLine: NSColor?
    let gutterText: NSColor
    let gutterCurrentText: NSColor
    /// Window chrome: toolbar, sidebar, issues panel and the area around the
    /// PDF. Nil keeps the system's colors.
    let chrome: NSColor?
    /// Dark themes force the dark appearance on the whole window.
    let isDark: Bool
    private let tokenColors: [LilyTokenKind: NSColor]

    /// Color for a token kind; nil means the plain text color.
    func color(for kind: LilyTokenKind) -> NSColor? { tokenColors[kind] }

    var appearance: NSAppearance? { isDark ? NSAppearance(named: .darkAqua) : nil }

    static var current: EditorTheme { theme(Preferences.editorTheme) }

    static func theme(_ name: Name) -> EditorTheme {
        switch name {
        case .everforest: everforest
        case .nord: nord
        case .catppuccinFrappe: catppuccinFrappe
        case .monokai: monokai
        case .system: system
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Everforest, dark, medium contrast (sainnhe/everforest palette.md):
    /// "warm and soft in order to protect developers' eyes".
    static let everforest: EditorTheme = {
        let red = hex(0xE67E80), orange = hex(0xE69875), yellow = hex(0xDBBC7F), green = hex(0xA7C080)
        let aqua = hex(0x83C092), blue = hex(0x7FBBB3), purple = hex(0xD699B6)
        let grey0 = hex(0x7A8478), grey1 = hex(0x859289), fg = hex(0xD3C6AA)
        return EditorTheme(
            name: .everforest, background: hex(0x2D353B), foreground: fg, insertionPoint: fg,
            selection: hex(0x475258), currentLine: hex(0x343F44), gutterText: grey0, gutterCurrentText: fg,
            chrome: hex(0x232A2E), isDark: true,
            tokenColors: [
                .comment: grey1, .string: aqua, .keyword: red, .command: green,
                .dynamic: orange, .articulation: orange, .spanner: orange,
                .rest: grey0, .duration: purple, .number: purple, .scheme: yellow,
                .delimiter: grey1, .barCheck: grey0, .variable: blue,
                .contextName: yellow, .property: blue, .markupText: aqua, .lyricText: aqua,
            ])
    }()

    /// Nord (nordtheme.com), following its syntax guidance: keywords nord9,
    /// calls nord8, types nord7, strings nord14, numbers nord15. Comments use
    /// the brightened nord3 of the official editor themes.
    static let nord: EditorTheme = {
        let nord4 = hex(0xD8DEE9), nord6 = hex(0xECEFF4), nord7 = hex(0x8FBCBB), nord8 = hex(0x88C0D0)
        let nord9 = hex(0x81A1C1), nord10 = hex(0x5E81AC), nord12 = hex(0xD08770), nord14 = hex(0xA3BE8C)
        let nord15 = hex(0xB48EAD), comment = hex(0x616E88)
        return EditorTheme(
            name: .nord, background: hex(0x2E3440), foreground: nord4, insertionPoint: nord4,
            selection: hex(0x434C5E), currentLine: hex(0x3B4252), gutterText: hex(0x4C566A),
            gutterCurrentText: nord4, chrome: hex(0x292E39), isDark: true,
            tokenColors: [
                .comment: comment, .string: nord14, .keyword: nord9, .command: nord8,
                .dynamic: nord12, .articulation: nord12, .spanner: nord9,
                .rest: comment, .duration: nord15, .number: nord15, .scheme: nord10,
                .delimiter: nord6, .barCheck: comment, .variable: nord8,
                .contextName: nord7, .property: nord7, .markupText: nord14, .lyricText: nord14,
            ])
    }()

    /// Catppuccin Frappé (catppuccin.com/palette), after its style guide:
    /// keywords mauve, functions blue, types yellow, strings green, numbers
    /// peach, comments overlay 2, cursor rosewater.
    static let catppuccinFrappe: EditorTheme = {
        let text = hex(0xC6D0F5), mauve = hex(0xCA9EE6), blue = hex(0x8CAAEE), yellow = hex(0xE5C890)
        let green = hex(0xA6D189), peach = hex(0xEF9F76), pink = hex(0xF4B8E4), sky = hex(0x99D1DB)
        let teal = hex(0x81C8BE), lavender = hex(0xBABBF1), overlay2 = hex(0x949CBB), overlay1 = hex(0x838BA7)
        return EditorTheme(
            name: .catppuccinFrappe, background: hex(0x303446), foreground: text, insertionPoint: hex(0xF2D5CF),
            // Selection: overlay 2 at 25%; current line: text at 10% (style guide).
            selection: hex(0x494E63), currentLine: hex(0x3F4458), gutterText: overlay1,
            gutterCurrentText: lavender, chrome: hex(0x292C3C), isDark: true,
            tokenColors: [
                .comment: overlay2, .string: green, .keyword: mauve, .command: blue,
                .dynamic: pink, .articulation: pink, .spanner: sky,
                .rest: overlay1, .duration: peach, .number: peach, .scheme: hex(0xF2D5CF),
                .delimiter: overlay2, .barCheck: overlay1, .variable: lavender,
                .contextName: yellow, .property: teal, .markupText: green, .lyricText: green,
            ])
    }()

    /// Monokai (Wimer Hazenberg's palette, as in Sublime Text and VS Code).
    static let monokai: EditorTheme = {
        let pink = hex(0xF92672), orange = hex(0xFD971F), yellow = hex(0xE6DB74), green = hex(0xA6E22E)
        let cyan = hex(0x66D9EF), purple = hex(0xAE81FF), comment = hex(0x75715E), muted = hex(0x90908A)
        return EditorTheme(
            name: .monokai, background: hex(0x272822), foreground: hex(0xF8F8F2), insertionPoint: hex(0xF8F8F0),
            selection: hex(0x49483E), currentLine: hex(0x3E3D32), gutterText: muted,
            gutterCurrentText: hex(0xF8F8F2), chrome: hex(0x1E1F1C), isDark: true,
            tokenColors: [
                .comment: comment, .string: yellow, .keyword: pink, .command: cyan,
                .dynamic: orange, .articulation: orange, .spanner: orange,
                .rest: muted, .duration: purple, .number: purple, .scheme: purple,
                .delimiter: hex(0xCFCFC2), .barCheck: comment, .variable: green,
                .contextName: cyan, .property: orange, .markupText: yellow, .lyricText: yellow,
            ])
    }()

    static let system = EditorTheme(
        name: .system, background: .textBackgroundColor, foreground: .textColor,
        insertionPoint: .controlAccentColor, selection: .selectedTextBackgroundColor, currentLine: nil,
        gutterText: .secondaryLabelColor, gutterCurrentText: .labelColor, chrome: nil, isDark: false,
        tokenColors: [
            .comment: .secondaryLabelColor, .string: .systemRed, .keyword: .systemPink, .command: .systemPurple,
            .dynamic: .systemOrange, .articulation: .systemOrange, .rest: .systemGray, .duration: .systemTeal,
            .spanner: .systemBrown, .delimiter: .secondaryLabelColor, .barCheck: .tertiaryLabelColor,
            .scheme: .systemBrown, .variable: .systemBlue, .contextName: .systemIndigo, .property: .systemCyan,
            .number: .systemBlue, .markupText: .systemGreen, .lyricText: .systemGreen,
        ])
}

// MARK: - SwiftUI

/// Window chrome color for SwiftUI panels, following the theme setting.
struct ThemedBackground: ViewModifier {
    @AppStorage(Preferences.Key.editorTheme) private var themeName = Preferences.defaultTheme.rawValue
    /// Used by the System theme.
    var fallback: Color

    func body(content: Content) -> some View {
        let theme = EditorTheme.theme(EditorTheme.Name(rawValue: themeName) ?? Preferences.defaultTheme)
        content.background(theme.chrome.map { Color(nsColor: $0) } ?? fallback)
    }
}

extension View {
    func themedBackground(fallback: Color = .clear) -> some View {
        modifier(ThemedBackground(fallback: fallback))
    }
}
