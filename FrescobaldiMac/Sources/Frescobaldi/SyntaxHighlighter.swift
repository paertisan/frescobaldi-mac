import AppKit
import FrescobaldiCore

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
