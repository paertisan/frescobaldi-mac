import AppKit
import FrescobaldiCore

/// Editor colors: the Monokai theme (dark, whatever the system appearance,
/// like in most code editors) or the system colors, which follow light and
/// dark mode and Increase Contrast.
struct EditorTheme {
    enum Name: String, CaseIterable, Identifiable {
        case monokai, system
        var id: String { rawValue }
        var title: String {
            switch self {
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
    /// A dark editor in a light window gets dark scrollers and find bar.
    let isDark: Bool
    private let tokenColors: [LilyTokenKind: NSColor]

    /// Color for a token kind; nil means the plain text color.
    func color(for kind: LilyTokenKind) -> NSColor? { tokenColors[kind] }

    static var current: EditorTheme {
        Preferences.editorTheme == .system ? .system : .monokai
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Monokai (Wimer Hazenberg's palette, as in Sublime Text and VS Code).
    static let monokai: EditorTheme = {
        let pink = hex(0xF92672), orange = hex(0xFD971F), yellow = hex(0xE6DB74), green = hex(0xA6E22E)
        let cyan = hex(0x66D9EF), purple = hex(0xAE81FF), comment = hex(0x75715E), muted = hex(0x90908A)
        return EditorTheme(
            name: .monokai, background: hex(0x272822), foreground: hex(0xF8F8F2), insertionPoint: hex(0xF8F8F0),
            selection: hex(0x49483E), currentLine: hex(0x3E3D32), gutterText: muted,
            gutterCurrentText: hex(0xF8F8F2), isDark: true,
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
        gutterText: .secondaryLabelColor, gutterCurrentText: .labelColor, isDark: false,
        tokenColors: [
            .comment: .secondaryLabelColor, .string: .systemRed, .keyword: .systemPink, .command: .systemPurple,
            .dynamic: .systemOrange, .articulation: .systemOrange, .rest: .systemGray, .duration: .systemTeal,
            .spanner: .systemBrown, .delimiter: .secondaryLabelColor, .barCheck: .tertiaryLabelColor,
            .scheme: .systemBrown, .variable: .systemBlue, .contextName: .systemIndigo, .property: .systemCyan,
            .number: .systemBlue, .markupText: .systemGreen, .lyricText: .systemGreen,
        ])
}

/// Colors the visible part of the editor with NSLayoutManager temporary
/// attributes. Keeps the lexer state at each line start, so after an edit
/// only the lines from the edit down to the visible end are re-lexed.
final class SyntaxHighlighter {
    private weak var layoutManager: NSLayoutManager?
    private let textStorage: NSTextStorage
    /// Lexer state at the start of line i, valid for i < states.count.
    private var states: [LilyLexerState] = [.initial]

    init(layoutManager: NSLayoutManager, textStorage: NSTextStorage) {
        self.layoutManager = layoutManager
        self.textStorage = textStorage
    }

    /// Drops states after the line containing `location` (its own start
    /// state is still good).
    func invalidate(from location: Int, lines: LineIndex) {
        let line = lines.line(at: location)
        if states.count > line + 1 { states.removeSubrange((line + 1)...) }
    }

    func invalidateAll() {
        states = [.initial]
    }

    /// Re-colors the lines touching `range`.
    func highlight(_ range: NSRange, lines: LineIndex) {
        guard let layoutManager, lines.length == textStorage.length else { return }
        let text = textStorage.string as NSString
        let first = lines.line(at: range.location)
        let last = lines.line(at: max(range.location, NSMaxRange(range) - 1))

        // Catch up from the last known state to the first visible line.
        var state = states[states.count - 1]
        var line = states.count - 1
        while line < first {
            state = LilyPondLexer.lex(text, range: lines.range(ofLine: line), from: state)
            line += 1
            states.append(state)
        }

        let start = lines.range(ofLine: first).location
        let endRange = lines.range(ofLine: last)
        let colorRange = NSRange(location: start, length: NSMaxRange(endRange) - start)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: colorRange)

        state = states[first]
        let theme = EditorTheme.current
        for line in first...last {
            state = LilyPondLexer.lex(text, range: lines.range(ofLine: line), from: state) { token in
                if let color = theme.color(for: token.kind) {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }
            }
            if line + 1 < states.count {
                if states[line + 1] != state {
                    // The edit changed how later lines start; their states are stale.
                    states[line + 1] = state
                    if states.count > line + 2 { states.removeSubrange((line + 2)...) }
                }
            } else if line + 1 == states.count {
                states.append(state)
            }
        }
    }
}
