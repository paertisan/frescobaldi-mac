import AppKit
import Combine
import FrescobaldiCore
import SwiftUI

/// A color theme for the whole window: the editor and its syntax colors,
/// plus the toolbar, sidebar, issues panel and the area around the PDF.
/// Dark themes give the window a dark appearance and light ones a light
/// appearance, whatever the system uses, so standard controls match.
/// "System" uses the system colors and follows light and dark mode.
struct EditorTheme: Identifiable {
    let id: String
    let name: String
    /// "Built-in" or the collection it comes from.
    let collection: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let insertionPoint: NSColor
    let selection: NSColor
    let selectionForeground: NSColor?
    /// Background of the line with the insertion point, if highlighted.
    let currentLine: NSColor?
    let gutterText: NSColor
    let gutterCurrentText: NSColor
    let gutterBackground: NSColor?
    /// Window chrome: toolbar, sidebar, issues panel and the area around the
    /// PDF. Nil keeps the system's colors.
    let chrome: NSColor?
    let tokenColors: [LilyTokenKind: NSColor]

    /// Color for a token kind; nil means the plain text color.
    func color(for kind: LilyTokenKind) -> NSColor? { tokenColors[kind] }

    /// Nil for System, which follows the app's appearance.
    var appearance: NSAppearance? {
        id == Self.systemID ? nil : NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// The theme for the current system appearance (see ThemeStore).
    static var current: EditorTheme { ThemeStore.shared.resolve() }

    static let systemID = "system"
}

// MARK: - Built-in themes

extension EditorTheme {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let builtIn: [EditorTheme] = [
        everforest, everforestLight, nord, catppuccinFrappe, catppuccinLatte, monokai, system,
    ]

    /// Everforest, medium contrast (sainnhe/everforest palette.md): "warm and
    /// soft in order to protect developers' eyes".
    private static func everforest(id: String, name: String, dark: Bool, bg0: UInt32, bgDim: UInt32, bg1: UInt32,
                                   bg3: UInt32, fg: UInt32, red: UInt32, orange: UInt32, yellow: UInt32,
                                   green: UInt32, aqua: UInt32, blue: UInt32, purple: UInt32, grey0: UInt32,
                                   grey1: UInt32) -> EditorTheme {
        let fg = hex(fg), red = hex(red), orange = hex(orange), yellow = hex(yellow), green = hex(green)
        let aqua = hex(aqua), blue = hex(blue), purple = hex(purple), grey0 = hex(grey0), grey1 = hex(grey1)
        return EditorTheme(
            id: id, name: name, collection: "Built-in", isDark: dark, background: hex(bg0), foreground: fg,
            insertionPoint: fg, selection: hex(bg3), selectionForeground: nil, currentLine: hex(bg1),
            gutterText: grey0, gutterCurrentText: fg, gutterBackground: nil, chrome: hex(bgDim),
            tokenColors: [
                .comment: grey1, .string: aqua, .keyword: red, .command: green,
                .dynamic: orange, .articulation: orange, .spanner: orange,
                .rest: grey0, .duration: purple, .number: purple, .scheme: yellow,
                .delimiter: grey1, .barCheck: grey0, .variable: blue,
                .contextName: yellow, .property: blue, .markupText: aqua, .lyricText: aqua,
            ])
    }

    static let everforest = everforest(
        id: "everforest", name: "Everforest Dark", dark: true, bg0: 0x2D353B, bgDim: 0x232A2E, bg1: 0x343F44,
        bg3: 0x475258, fg: 0xD3C6AA, red: 0xE67E80, orange: 0xE69875, yellow: 0xDBBC7F, green: 0xA7C080,
        aqua: 0x83C092, blue: 0x7FBBB3, purple: 0xD699B6, grey0: 0x7A8478, grey1: 0x859289)

    static let everforestLight = everforest(
        id: "everforest-light", name: "Everforest Light", dark: false, bg0: 0xFDF6E3, bgDim: 0xEFEBD4,
        bg1: 0xF4F0D9, bg3: 0xE6E2CC, fg: 0x5C6A72, red: 0xF85552, orange: 0xF57D26, yellow: 0xDFA000,
        green: 0x8DA101, aqua: 0x35A77C, blue: 0x3A94C5, purple: 0xDF69BA, grey0: 0xA6B0A0, grey1: 0x939F91)

    /// Nord (nordtheme.com), following its syntax guidance: keywords nord9,
    /// calls nord8, types nord7, strings nord14, numbers nord15. Comments use
    /// the brightened nord3 of the official editor themes.
    static let nord: EditorTheme = {
        let nord4 = hex(0xD8DEE9), nord6 = hex(0xECEFF4), nord7 = hex(0x8FBCBB), nord8 = hex(0x88C0D0)
        let nord9 = hex(0x81A1C1), nord10 = hex(0x5E81AC), nord12 = hex(0xD08770), nord14 = hex(0xA3BE8C)
        let nord15 = hex(0xB48EAD), comment = hex(0x616E88)
        return EditorTheme(
            id: "nord", name: "Nord", collection: "Built-in", isDark: true, background: hex(0x2E3440),
            foreground: nord4, insertionPoint: nord4, selection: hex(0x434C5E), selectionForeground: nil,
            currentLine: hex(0x3B4252), gutterText: hex(0x4C566A), gutterCurrentText: nord4, gutterBackground: nil,
            chrome: hex(0x292E39),
            tokenColors: [
                .comment: comment, .string: nord14, .keyword: nord9, .command: nord8,
                .dynamic: nord12, .articulation: nord12, .spanner: nord9,
                .rest: comment, .duration: nord15, .number: nord15, .scheme: nord10,
                .delimiter: nord6, .barCheck: comment, .variable: nord8,
                .contextName: nord7, .property: nord7, .markupText: nord14, .lyricText: nord14,
            ])
    }()

    /// Catppuccin (catppuccin.com/palette), after its style guide: keywords
    /// mauve, functions blue, types yellow, strings green, numbers peach,
    /// comments overlay 2, cursor rosewater; selection overlay 2 at 25% and
    /// the cursor line text at 10%.
    private static func catppuccin(id: String, name: String, dark: Bool, base: UInt32, mantle: UInt32,
                                   text: UInt32, rosewater: UInt32, mauve: UInt32, blue: UInt32, yellow: UInt32,
                                   green: UInt32, peach: UInt32, pink: UInt32, sky: UInt32, teal: UInt32,
                                   lavender: UInt32, overlay2: UInt32, overlay1: UInt32, selection: UInt32,
                                   cursorLine: UInt32) -> EditorTheme {
        let overlay1 = hex(overlay1)
        return EditorTheme(
            id: id, name: name, collection: "Built-in", isDark: dark, background: hex(base), foreground: hex(text),
            insertionPoint: hex(rosewater), selection: hex(selection), selectionForeground: nil,
            currentLine: hex(cursorLine), gutterText: overlay1, gutterCurrentText: hex(lavender),
            gutterBackground: nil, chrome: hex(mantle),
            tokenColors: [
                .comment: hex(overlay2), .string: hex(green), .keyword: hex(mauve), .command: hex(blue),
                .dynamic: hex(pink), .articulation: hex(pink), .spanner: hex(sky),
                .rest: overlay1, .duration: hex(peach), .number: hex(peach), .scheme: hex(rosewater),
                .delimiter: hex(overlay2), .barCheck: overlay1, .variable: hex(lavender),
                .contextName: hex(yellow), .property: hex(teal), .markupText: hex(green), .lyricText: hex(green),
            ])
    }

    static let catppuccinFrappe = catppuccin(
        id: "catppuccin-frappe", name: "Catppuccin Frappé", dark: true, base: 0x303446, mantle: 0x292C3C,
        text: 0xC6D0F5, rosewater: 0xF2D5CF, mauve: 0xCA9EE6, blue: 0x8CAAEE, yellow: 0xE5C890, green: 0xA6D189,
        peach: 0xEF9F76, pink: 0xF4B8E4, sky: 0x99D1DB, teal: 0x81C8BE, lavender: 0xBABBF1, overlay2: 0x949CBB,
        overlay1: 0x838BA7, selection: 0x494E63, cursorLine: 0x3F4458)

    static let catppuccinLatte = catppuccin(
        id: "catppuccin-latte", name: "Catppuccin Latte", dark: false, base: 0xEFF1F5, mantle: 0xE6E9EF,
        text: 0x4C4F69, rosewater: 0xDC8A78, mauve: 0x8839EF, blue: 0x1E66F5, yellow: 0xDF8E1D, green: 0x40A02B,
        peach: 0xFE640B, pink: 0xEA76CB, sky: 0x04A5E5, teal: 0x179299, lavender: 0x7287FD, overlay2: 0x7C7F93,
        overlay1: 0x8C8FA1, selection: 0xD2D4DC, cursorLine: 0xDFE1E7)

    /// Monokai (Wimer Hazenberg's palette, as in Sublime Text and VS Code).
    static let monokai: EditorTheme = {
        let pink = hex(0xF92672), orange = hex(0xFD971F), yellow = hex(0xE6DB74), green = hex(0xA6E22E)
        let cyan = hex(0x66D9EF), purple = hex(0xAE81FF), comment = hex(0x75715E), muted = hex(0x90908A)
        return EditorTheme(
            id: "monokai", name: "Monokai", collection: "Built-in", isDark: true, background: hex(0x272822),
            foreground: hex(0xF8F8F2), insertionPoint: hex(0xF8F8F0), selection: hex(0x49483E),
            selectionForeground: nil, currentLine: hex(0x3E3D32), gutterText: muted,
            gutterCurrentText: hex(0xF8F8F2), gutterBackground: nil, chrome: hex(0x1E1F1C),
            tokenColors: [
                .comment: comment, .string: yellow, .keyword: pink, .command: cyan,
                .dynamic: orange, .articulation: orange, .spanner: orange,
                .rest: muted, .duration: purple, .number: purple, .scheme: purple,
                .delimiter: hex(0xCFCFC2), .barCheck: comment, .variable: green,
                .contextName: cyan, .property: orange, .markupText: yellow, .lyricText: yellow,
            ])
    }()

    static let system = EditorTheme(
        id: systemID, name: "System", collection: "Built-in", isDark: false, background: .textBackgroundColor,
        foreground: .textColor, insertionPoint: .controlAccentColor, selection: .selectedTextBackgroundColor,
        selectionForeground: nil, currentLine: nil, gutterText: .secondaryLabelColor,
        gutterCurrentText: .labelColor, gutterBackground: nil, chrome: nil,
        tokenColors: [
            .comment: .secondaryLabelColor, .string: .systemRed, .keyword: .systemPink, .command: .systemPurple,
            .dynamic: .systemOrange, .articulation: .systemOrange, .rest: .systemGray, .duration: .systemTeal,
            .spanner: .systemBrown, .delimiter: .secondaryLabelColor, .barCheck: .tertiaryLabelColor,
            .scheme: .systemBrown, .variable: .systemBlue, .contextName: .systemIndigo, .property: .systemCyan,
            .number: .systemBlue, .markupText: .systemGreen, .lyricText: .systemGreen,
        ])
}

// MARK: - Imported themes (Resources/Themes/*.json, from scripts/import-jetbrains-themes.py)

private struct ThemeFile: Decodable {
    struct Theme: Decodable {
        var id: String
        var name: String
        var dark: Bool
        var background: String
        var foreground: String
        var caret: String?
        var currentLine: String?
        var selection: String?
        var selectionForeground: String?
        var gutterText: String?
        var gutterCurrentText: String?
        var gutterBackground: String?
        var tokens: [String: String]
    }

    var themes: [Theme]
}

private func parseColor(_ string: String?) -> NSColor? {
    guard let string, string.hasPrefix("#"), let value = UInt32(string.dropFirst(), radix: 16) else { return nil }
    return EditorTheme.hex(value)
}

private extension NSColor {
    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}

extension EditorTheme {
    /// Themes in `Resources/Themes/<collection>.json`.
    static func loadCollection(_ url: URL) -> [EditorTheme] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ThemeFile.self, from: data) else { return [] }
        let collection = url.deletingPathExtension().lastPathComponent.capitalized
        return file.themes.compactMap { theme in
            guard let background = parseColor(theme.background), let foreground = parseColor(theme.foreground) else { return nil }
            var tokens: [LilyTokenKind: NSColor] = [:]
            for (key, value) in theme.tokens {
                if let kind = LilyTokenKind(rawValue: key), let tokenColor = parseColor(value) { tokens[kind] = tokenColor }
            }
            let gutterBackground = parseColor(theme.gutterBackground)
            // Chrome a little darker than the editor, like the IDE's panels.
            let chrome = theme.dark ? (gutterBackground.flatMap { $0 == background ? nil : $0 }
                                           ?? background.mixed(with: .black, 0.18))
                                    : background.mixed(with: .black, 0.04)
            return EditorTheme(
                id: theme.id, name: theme.name, collection: collection, isDark: theme.dark,
                background: background, foreground: foreground, insertionPoint: parseColor(theme.caret) ?? foreground,
                selection: parseColor(theme.selection) ?? foreground.mixed(with: background, 0.75),
                selectionForeground: parseColor(theme.selectionForeground), currentLine: parseColor(theme.currentLine),
                gutterText: parseColor(theme.gutterText) ?? foreground.mixed(with: background, 0.5),
                gutterCurrentText: parseColor(theme.gutterCurrentText) ?? foreground,
                gutterBackground: gutterBackground, chrome: chrome, tokenColors: tokens)
        }
    }
}

// MARK: - Choosing the theme

/// All themes, and which one applies: the light or dark theme setting,
/// following the system appearance.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    let all: [EditorTheme]
    private let byID: [String: EditorTheme]
    /// The theme in use; SwiftUI views observe this.
    @Published private(set) var current: EditorTheme
    private var observations: [Any] = []

    private init() {
        var themes = EditorTheme.builtIn
        let folder = AppResources.root.appendingPathComponent("Themes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            themes += EditorTheme.loadCollection(file)
        }
        all = themes
        byID = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        current = EditorTheme.everforest
        current = resolve()
        observations.append(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        // Follow the system switching between light and dark mode.
        observations.append(NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceChanged() }
        })
    }

    func theme(id: String) -> EditorTheme? { byID[id] }

    var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func resolve() -> EditorTheme {
        let id = systemIsDark ? Preferences.darkThemeID : Preferences.lightThemeID
        return byID[id] ?? (systemIsDark ? .everforest : .everforestLight)
    }

    private func refresh() {
        let theme = resolve()
        if theme.id != current.id { current = theme }
    }

    private func appearanceChanged() {
        guard resolve().id != current.id else { return }
        // Windows and editors re-apply their style on this notification.
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }
}

// MARK: - SwiftUI

/// Window chrome color for SwiftUI panels, following the theme.
struct ThemedBackground: ViewModifier {
    @ObservedObject private var store = ThemeStore.shared
    /// Used by the System theme.
    var fallback: Color

    func body(content: Content) -> some View {
        content.background(store.current.chrome.map { Color(nsColor: $0) } ?? fallback)
    }
}

extension View {
    func themedBackground(fallback: Color = .clear) -> some View {
        modifier(ThemedBackground(fallback: fallback))
    }
}

extension EditorTheme {
    /// A line of LilyPond in this theme's colors, for previews.
    func sample(_ source: String = "\\relative c'' { \\clef treble c4\\p d-. e( f) | g2 r4 \\bar \"|.\" } % coda") -> AttributedString {
        let text = source as NSString
        let result = NSMutableAttributedString(string: source, attributes: [.foregroundColor: foreground])
        LilyPondLexer.lex(text, range: NSRange(location: 0, length: text.length)) { token in
            if let color = color(for: token.kind) { result.addAttribute(.foregroundColor, value: color, range: token.range) }
        }
        return (try? AttributedString(result, including: \.appKit)) ?? AttributedString(source)
    }
}
