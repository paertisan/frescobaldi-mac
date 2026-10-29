import Foundation

/// What a highlighted run of LilyPond source is.
public enum LilyTokenKind: String, CaseIterable, Sendable {
    case comment
    case string
    /// Backslash keywords such as `\score`, `\header`, `\override`.
    case keyword
    /// Built-in music functions (`\relative`, `\clef`) and markup commands.
    case command
    /// `\p`, `\ff`, `\<`, `\!`, `\cresc`.
    case dynamic
    /// `-.`, `^>`, `-1`, `\staccato`, `\fermata`, `\1` (string number).
    case articulation
    /// A note name with its octave marks, accidental marks and octave check.
    case pitch
    /// `r`, `R`, `s`, `\rest`, `\skip`.
    case rest
    /// `4`, `8.`, `2*3/4`, `\breve`, tremolo `:16`.
    case duration
    /// Slurs, phrasing slurs, beams, ties, ligatures, lyric hyphens/extenders.
    case spanner
    /// `{ } << >> < > \\ =`.
    case delimiter
    /// `|`.
    case barCheck
    /// Scheme code after `#` or `$`.
    case scheme
    /// A top-level assignment name (`melody = ...`) or a user variable reference (`\melody`).
    case variable
    /// `Staff`, `Voice`, ...
    case contextName
    /// `instrumentName` in `\set Staff.instrumentName`, `title` in `\header { title = ... }`.
    case property
    /// Numbers that aren't durations (`\time 3/4`, `\repeat volta 2`, `#0.5`).
    case number
    /// Plain words in markup.
    case markupText
    /// Syllables in lyric mode.
    case lyricText
}

/// A token: a kind plus a UTF-16 range in the lexed string.
public struct LilyToken: Equatable, Sendable {
    public var kind: LilyTokenKind
    public var range: NSRange

    public init(kind: LilyTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// Lexer state at a line start. Lexing a line from the state that the
/// previous line ended with gives the same tokens as lexing the whole text
/// in one go, so an editor can keep one checkpoint per line and re-lex only
/// from the edited line until the state matches the old checkpoint again.
public struct LilyLexerState: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case music, lyrics, markup, drums, scheme
    }

    struct Frame: Equatable, Sendable {
        var mode: Mode
        /// Brace/`<<` depth for LilyPond frames, parenthesis depth for Scheme.
        var depth: Int
        /// A LilyPond frame opened by `#{`; only `#}` closes it.
        var embedded: Bool
    }

    /// Mode stack; never empty. `frames[0]` is the top-level music frame.
    var frames: [Frame]
    var inBlockComment: Bool
    var inString: Bool
    /// Mode entered at the next `{` or `<<` (after `\lyricmode`, `\markup`, ...).
    var pending: Mode?
    /// The previous token was a note, rest, chord or duration, so a following
    /// number is a duration.
    var afterMusicItem: Bool

    public static let initial = LilyLexerState(
        frames: [Frame(mode: .music, depth: 0, embedded: false)],
        inBlockComment: false, inString: false, pending: nil, afterMusicItem: false)

    var top: Frame {
        get { frames[frames.count - 1] }
        set { frames[frames.count - 1] = newValue }
    }

    /// At top level, outside any braces.
    var isTopLevel: Bool { frames.count == 1 && frames[0].depth == 0 }
}

/// A resumable LilyPond lexer for syntax highlighting, modeled on python-ly's
/// `ly.lex.lilypond`. It is not a parser: it errs towards plausible colors
/// and never fails.
public enum LilyPondLexer {
    /// Lexes `range` of `text` starting in `state` and returns the state at the
    /// end of the range. The returned state is only meaningful when the range
    /// ends at a line start (or the end of the text).
    ///
    /// Tokens are reported in order and never cross a line break, have zero
    /// length, or fall outside `range`.
    @discardableResult
    public static func lex(
        _ text: NSString,
        range: NSRange,
        from state: LilyLexerState = .initial,
        emit: ((LilyToken) -> Void)? = nil
    ) -> LilyLexerState {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 else { return state }
        var buffer = [unichar](repeating: 0, count: clamped.length)
        buffer.withUnsafeMutableBufferPointer { ptr in
            text.getCharacters(ptr.baseAddress!, range: clamped)
        }
        var scanner = Scanner(chars: buffer, base: clamped.location, state: state, emit: emit)
        scanner.run()
        return scanner.state
    }

    /// Convenience: all tokens of `text`.
    public static func tokens(in text: String) -> [LilyToken] {
        var result: [LilyToken] = []
        let ns = text as NSString
        lex(ns, range: NSRange(location: 0, length: ns.length)) { result.append($0) }
        return result
    }
}

// MARK: - Scanner

private let BACKSLASH: unichar = 0x5C
private let QUOTE: unichar = 0x22

@inline(__always) private func ch(_ s: Unicode.Scalar) -> unichar { unichar(s.value) }

/// Line terminators as NSString sees them (`lineRange(for:)`), so that line
/// checkpoints taken by the editor are real lexer line starts.
@inline(__always) private func isNewline(_ c: unichar) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 || c == 0x85
}
@inline(__always) private func isSpace(_ c: unichar) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0C || c == 0x0B || c == 0xA0
}
@inline(__always) private func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isASCIILetter(_ c: unichar) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}
/// Letters for identifiers: ASCII letters plus any non-ASCII BMP letter.
/// Surrogates count as letters too, so pairs are never split.
@inline(__always) private func isLetter(_ c: unichar) -> Bool {
    if c < 0x80 { return isASCIILetter(c) }
    if c >= 0xD800 && c <= 0xDFFF { return true }
    guard let scalar = Unicode.Scalar(c) else { return false }
    return CharacterSet.letters.contains(scalar)
}

private let validDurations: Set<Int> = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048]
private let dynamicWords: Set<String> = [
    "f", "ff", "fff", "ffff", "fffff", "p", "pp", "ppp", "pppp", "ppppp",
    "mf", "mp", "fp", "sp", "spp", "sf", "sff", "sfz", "rfz", "n",
    "cresc", "decresc", "dim", "cr", "decr",
]
private let lyricModeCommands: Set<String> = ["lyricmode", "lyrics", "addlyrics", "lyricsto"]
private let musicModeCommands: Set<String> = [
    "notemode", "chordmode", "chords", "figuremode", "figures", "fixed", "relative",
]
private let drumModeCommands: Set<String> = ["drummode", "drums"]
private let markupModeCommands: Set<String> = ["markup", "markuplist"]
private let propertyCommands: Set<String> = [
    "set", "unset", "override", "revert", "tweak", "overrideProperty", "omit", "hide", "undo",
]
/// Commands whose next number is a duration (`\partial 4`, `\tuplet 3/2 8`).
private let durationCommands: Set<String> = ["partial", "skip", "tempo", "tuplet", "tupletSpan"]

private struct Scanner {
    let chars: [unichar]
    let base: Int
    var state: LilyLexerState
    let emit: ((LilyToken) -> Void)?
    var i = 0

    // Transient context, reset at every line break so that lexing from a
    // line-start checkpoint matches lexing the whole text.
    var expectProperty = false
    var afterDot = false
    var durationNext = false

    init(chars: [unichar], base: Int, state: LilyLexerState, emit: ((LilyToken) -> Void)?) {
        self.chars = chars
        self.base = base
        self.state = state
        self.emit = emit
    }

    var n: Int { chars.count }

    func at(_ j: Int) -> unichar { j < n ? chars[j] : 0 }

    func add(_ kind: LilyTokenKind, _ start: Int, _ end: Int) {
        guard let emit, end > start else { return }
        emit(LilyToken(kind: kind, range: NSRange(location: base + start, length: end - start)))
    }

    func lineEnd(from j: Int) -> Int {
        var k = j
        while k < n && !isNewline(chars[k]) { k += 1 }
        return k
    }

    mutating func run() {
        while i < n {
            let c = chars[i]
            if isNewline(c) {
                i += 1
                expectProperty = false
                afterDot = false
                durationNext = false
                continue
            }
            if state.inBlockComment { continueBlockComment(); continue }
            if state.inString { continueString(start: i); continue }
            if isSpace(c) { i += 1; continue }
            if state.top.mode == .scheme {
                lexScheme(c)
            } else {
                lexLily(c)
            }
        }
    }

    // MARK: Comments and strings (shared by LilyPond and Scheme)

    mutating func continueBlockComment(start: Int? = nil) {
        let s = start ?? i
        let scheme = state.top.mode == .scheme
        let close0 = scheme ? ch("|") : ch("%")
        let close1 = scheme ? ch("#") : ch("}")
        while i < n && !isNewline(chars[i]) {
            if chars[i] == close0 && at(i + 1) == close1 {
                i += 2
                state.inBlockComment = false
                break
            }
            i += 1
        }
        add(.comment, s, i)
    }

    mutating func continueString(start: Int) {
        while i < n && !isNewline(chars[i]) {
            let c = chars[i]
            if c == BACKSLASH && i + 1 < n && !isNewline(chars[i + 1]) {
                i += 2
                continue
            }
            i += 1
            if c == QUOTE {
                state.inString = false
                break
            }
        }
        add(.string, start, i)
    }

    mutating func startString() {
        let s = i
        i += 1
        state.inString = true
        continueString(start: s)
    }

    // MARK: LilyPond

    mutating func lexLily(_ c: unichar) {
        let mode = state.top.mode
        switch c {
        case ch("%"):
            if at(i + 1) == ch("{") {
                let s = i
                i += 2
                state.inBlockComment = true
                continueBlockComment(start: s)
            } else {
                let e = lineEnd(from: i)
                add(.comment, i, e)
                i = e
            }
            return
        case QUOTE:
            if state.pending == .markup { state.pending = nil }
            startString()
            state.afterMusicItem = false
            return
        case ch("#"), ch("$"):
            lexSchemeStart()
            return
        case BACKSLASH:
            lexBackslash()
            return
        case ch("{"):
            openBrace(length: 1)
            return
        case ch("}"):
            closeBrace(length: 1)
            return
        default:
            break
        }

        if c == ch("<") && at(i + 1) == ch("<") { openBrace(length: 2); return }
        if c == ch(">") && at(i + 1) == ch(">") { closeBrace(length: 2); return }

        switch mode {
        case .markup:
            lexMarkupText()
        case .lyrics:
            // `\set stanza = "1."` inside lyrics names a property, not a syllable.
            if expectProperty || afterDot { lexMusic(c) } else { lexLyrics(c) }
        default:
            if state.pending == .markup {
                lexMarkupText()
            } else {
                lexMusic(c)
            }
        }
    }

    mutating func openBrace(length: Int) {
        add(.delimiter, i, i + length)
        i += length
        if let pending = state.pending, pending != .scheme {
            state.frames.append(.init(mode: pending, depth: 1, embedded: false))
            state.pending = nil
        } else {
            state.top.depth += 1
        }
        state.afterMusicItem = false
        durationNext = false
    }

    mutating func closeBrace(length: Int) {
        add(.delimiter, i, i + length)
        i += length
        state.pending = nil
        state.afterMusicItem = false
        if state.top.depth > 0 { state.top.depth -= 1 }
        if state.frames.count > 1 && state.top.depth == 0 && !state.top.embedded {
            state.frames.removeLast()
        }
    }

    /// `\word`, `\\`, `\(`, `\<`, `\1`, ...
    mutating func lexBackslash() {
        let s = i
        let next = at(i + 1)
        switch next {
        case BACKSLASH:
            i += 2
            add(.delimiter, s, i)
            state.afterMusicItem = false
            return
        case ch("("), ch(")"), ch("["), ch("]"):
            i += 2
            add(.spanner, s, i)
            return
        case ch("<"), ch(">"), ch("!"):
            i += 2
            add(.dynamic, s, i)
            return
        default:
            break
        }
        if isDigit(next) {
            i += 1
            while i < n && isDigit(chars[i]) { i += 1 }
            add(.articulation, s, i)
            return
        }
        guard isLetter(next) else {
            // A lone backslash: nothing to color.
            i += 1
            return
        }
        i += 1
        let wordStart = i
        scanIdentifier()
        let word = String(decoding: chars[wordStart..<i], as: UTF16.self)
        classifyCommand(word, start: s)
    }

    mutating func classifyCommand(_ word: String, start s: Int) {
        let mode = state.top.mode
        let inMarkup = mode == .markup || state.pending == .markup

        if inMarkup {
            // Inside markup every backslash word is a markup command (or a
            // user-defined one); the pending markup stays active.
            add(.command, s, i)
            return
        }
        if dynamicWords.contains(word) {
            add(.dynamic, s, i)
            return
        }
        if word == "breve" || word == "longa" || word == "maxima" {
            add(.duration, s, i)
            scanDurationTail()
            state.afterMusicItem = true
            durationNext = false
            return
        }
        if word == "rest" || word == "skip" {
            add(.rest, s, i)
            if word == "skip" { durationNext = true }
            state.afterMusicItem = word == "rest"
            return
        }
        if LilyPondWords.articulations.contains(word) {
            add(.articulation, s, i)
            return
        }
        if LilyPondWords.contexts.contains(word) {
            // `\context { \Staff ... }`
            add(.contextName, s, i)
            state.afterMusicItem = false
            return
        }

        state.afterMusicItem = false
        if LilyPondWords.keywords.contains(word) {
            add(.keyword, s, i)
        } else if LilyPondWords.musicCommands.contains(word)
                    || LilyPondWords.markupCommands.contains(word) {
            add(.command, s, i)
        } else {
            add(.variable, s, i)
            // `\addlyrics \verseOne`: a variable satisfies the pending mode.
            if state.pending != nil { state.pending = nil }
            return
        }

        if propertyCommands.contains(word) { expectProperty = true }
        if durationCommands.contains(word) { durationNext = true }
        if lyricModeCommands.contains(word) {
            state.pending = .lyrics
        } else if markupModeCommands.contains(word) {
            state.pending = .markup
        } else if drumModeCommands.contains(word) {
            state.pending = .drums
        } else if word == "notemode" || word == "chordmode" || word == "chords"
                    || word == "figuremode" || word == "figures" {
            state.pending = .music
        } else if musicModeCommands.contains(word) && mode != .music {
            // \relative/\fixed inside lyrics or drums switch back to notes.
            state.pending = .music
        }
    }

    /// python-ly's identifier: letters, with single `-` or `_` between letter runs.
    mutating func scanIdentifier() {
        while i < n {
            if isLetter(chars[i]) {
                i += 1
            } else if (chars[i] == ch("-") || chars[i] == ch("_")) && i + 1 < n && isLetter(chars[i + 1]) {
                i += 2
            } else {
                break
            }
        }
    }

    /// Dots and `*n/m` scaling after a duration.
    mutating func scanDurationTail() {
        let s = i
        while i < n && chars[i] == ch(".") { i += 1 }
        while true {
            var j = i
            guard at(j) == ch("*") else { break }
            j += 1
            while j < n && isSpace(chars[j]) { j += 1 }
            guard isDigit(at(j)) else { break }
            while j < n && isDigit(chars[j]) { j += 1 }
            if at(j) == ch("/") && isDigit(at(j + 1)) {
                j += 1
                while j < n && isDigit(chars[j]) { j += 1 }
            }
            i = j
        }
        add(.duration, s, i)
    }

    mutating func lexMusic(_ c: unichar) {
        let mode = state.top.mode

        if isDigit(c) {
            lexNumber()
            return
        }
        if isLetter(c) {
            lexMusicWord(drums: mode == .drums)
            return
        }

        switch c {
        case ch("<"):
            add(.delimiter, i, i + 1)
            i += 1
            state.afterMusicItem = false
        case ch(">"):
            add(.delimiter, i, i + 1)
            i += 1
            state.afterMusicItem = true // chord end, a duration may follow
        case ch("|"):
            add(.barCheck, i, i + 1)
            i += 1
            state.afterMusicItem = false
        case ch("("), ch(")"), ch("["), ch("]"), ch("~"):
            add(.spanner, i, i + 1)
            i += 1
        case ch("-"), ch("_"), ch("^"):
            lexDirection()
        case ch("="):
            add(.delimiter, i, i + 1)
            i += 1
            state.afterMusicItem = false
        case ch(":"):
            // Tremolo `:16`, or a bare `:` (chord mode) which stays plain.
            let s = i
            i += 1
            if state.afterMusicItem && isDigit(at(i)) {
                while i < n && isDigit(chars[i]) { i += 1 }
                add(.duration, s, i)
            }
        case ch("."):
            // `Staff.TimeSignature`: the next word is a property.
            i += 1
            afterDot = true
            return
        default:
            i += 1
            state.afterMusicItem = false
        }
        afterDot = false
    }

    /// `-.`, `^>`, `_3`, `-\staccato`, `^"text"`.
    mutating func lexDirection() {
        let s = i
        let next = at(i + 1)
        switch next {
        case ch("."), ch(">"), ch("|"), ch("!"), ch("+"), ch("^"), ch("_"), ch("-"):
            i += 2
            add(.articulation, s, i)
        case _ where isDigit(next):
            i += 1
            while i < n && isDigit(chars[i]) { i += 1 }
            add(.articulation, s, i)
        case BACKSLASH, QUOTE, ch("#"), ch("$"):
            i += 1
            add(.articulation, s, i)
        default:
            i += 1
        }
    }

    mutating func lexNumber() {
        let s = i
        while i < n && isDigit(chars[i]) { i += 1 }
        // Fraction: \time 3/4, \tuplet 3/2
        if at(i) == ch("/") && isDigit(at(i + 1)) {
            i += 1
            while i < n && isDigit(chars[i]) { i += 1 }
            add(.number, s, i)
            state.afterMusicItem = false
            return
        }
        let digits = String(decoding: chars[s..<i], as: UTF16.self)
        if (state.afterMusicItem || durationNext), let value = Int(digits), validDurations.contains(value) {
            add(.duration, s, i)
            scanDurationTail()
            state.afterMusicItem = true
            durationNext = false
            return
        }
        // Decimal number: \override ... = 1.5 (rare without #, but legal)
        if at(i) == ch(".") && isDigit(at(i + 1)) {
            i += 1
            while i < n && isDigit(chars[i]) { i += 1 }
        }
        add(.number, s, i)
        state.afterMusicItem = false
    }

    /// The first non-blank character after `j` on the same line.
    func peekNonBlank(from j: Int) -> (index: Int, char: unichar) {
        var k = j
        while k < n && isSpace(chars[k]) { k += 1 }
        return (k, at(k))
    }

    mutating func lexMusicWord(drums: Bool) {
        let s = i
        scanIdentifier()
        let word = String(decoding: chars[s..<i], as: UTF16.self)
        let wasAfterDot = afterDot
        afterDot = false

        if expectProperty || wasAfterDot {
            add(LilyPondWords.contexts.contains(word) ? .contextName : .property, s, i)
            // `\override Staff.NoteHead.color`: keep going while a dot follows.
            if at(i) != ch(".") { expectProperty = false }
            state.afterMusicItem = false
            return
        }
        if LilyPondWords.contexts.contains(word) {
            add(.contextName, s, i)
            state.afterMusicItem = false
            return
        }
        // Assignment: `name = ...` (variable at top level, property inside a block).
        let peek = peekNonBlank(from: i)
        if peek.char == ch("=") {
            let after = at(peek.index + 1)
            if after != ch("'") && after != ch(",") && after != ch("=") {
                add(state.isTopLevel ? .variable : .property, s, i)
                state.afterMusicItem = false
                return
            }
        }
        if word == "r" || word == "R" || word == "s" {
            add(.rest, s, i)
            state.afterMusicItem = true
            return
        }
        let isPitch = word == "q" || LilyPondWords.pitchNames.contains(word)
            || (drums && word.utf16.allSatisfy { isASCIILetter($0) })
        if isPitch {
            // Octave marks, reminder/cautionary accidental, octave check.
            while i < n && (chars[i] == ch("'") || chars[i] == ch(",")) { i += 1 }
            if at(i) == ch("!") || at(i) == ch("?") { i += 1 }
            if at(i) == ch("=") {
                i += 1
                while i < n && (chars[i] == ch("'") || chars[i] == ch(",")) { i += 1 }
            }
            add(.pitch, s, i)
            state.afterMusicItem = true
            return
        }
        // Unknown word (`\clef treble`, `\repeat volta`): leave it plain.
        state.afterMusicItem = false
    }

    mutating func lexMarkupText() {
        let s = i
        while i < n {
            let c = chars[i]
            if isSpace(c) || isNewline(c) || c == BACKSLASH || c == QUOTE || c == ch("{")
                || c == ch("}") || c == ch("#") || c == ch("$") || c == ch("%") {
                break
            }
            i += 1
        }
        if i == s { i += 1; return }
        add(.markupText, s, i)
        if state.top.mode != .markup { state.pending = nil }
    }

    mutating func lexLyrics(_ c: unichar) {
        if isDigit(c) {
            lexNumber()
            return
        }
        let s = i
        while i < n {
            let c = chars[i]
            if isSpace(c) || isNewline(c) || isDigit(c) || c == BACKSLASH || c == QUOTE
                || c == ch("{") || c == ch("}") {
                break
            }
            // `<<`/`>>` and comments end a syllable too.
            if (c == ch("<") && at(i + 1) == ch("<")) || (c == ch(">") && at(i + 1) == ch(">")) || c == ch("%") {
                break
            }
            i += 1
        }
        if i == s { i += 1; return }
        let word = String(decoding: chars[s..<i], as: UTF16.self)
        switch word {
        case "--", "__", "~":
            add(.spanner, s, i)
            state.afterMusicItem = false
        case "|":
            add(.barCheck, s, i)
            state.afterMusicItem = false
        case "=":
            // `\set stanza = "1."`
            add(.delimiter, s, i)
            state.afterMusicItem = false
        default:
            add(.lyricText, s, i)
            state.afterMusicItem = true
        }
    }

    // MARK: Scheme

    /// `#` or `$` in LilyPond: an embedded Scheme expression.
    mutating func lexSchemeStart() {
        let s = i
        state.afterMusicItem = false
        state.pending = nil

        // `#}` closes an embedded LilyPond block.
        if chars[i] == ch("#") && at(i + 1) == ch("}") && state.top.embedded {
            i += 2
            add(.scheme, s, i)
            state.frames.removeLast()
            return
        }
        i += 1
        // `##t`: the second hash belongs to the Scheme value.
        if at(i) == ch("{") && chars[s] == ch("#") {
            i += 1
            add(.scheme, s, i)
            state.frames.append(.init(mode: .music, depth: 0, embedded: true))
            return
        }
        while i < n && (chars[i] == ch("'") || chars[i] == ch("`") || chars[i] == ch(",")) { i += 1 }
        if at(i) == ch("@") && at(i - 1) == ch(",") { i += 1 }
        let c = at(i)
        if c == ch("(") {
            i += 1
            add(.scheme, s, i)
            state.frames.append(.init(mode: .scheme, depth: 1, embedded: false))
            return
        }
        add(.scheme, s, i)
        if c == QUOTE {
            startString()
            return
        }
        if i >= n || isSpace(c) || isNewline(c) { return }
        lexSchemeAtom()
    }

    mutating func lexScheme(_ c: unichar) {
        switch c {
        case ch(";"):
            let e = lineEnd(from: i)
            add(.comment, i, e)
            i = e
        case QUOTE:
            startString()
        case ch("("):
            add(.scheme, i, i + 1)
            i += 1
            state.top.depth += 1
        case ch(")"):
            add(.scheme, i, i + 1)
            i += 1
            state.top.depth -= 1
            if state.top.depth <= 0 && state.frames.count > 1 {
                state.frames.removeLast()
            }
        case ch("#"):
            let next = at(i + 1)
            if next == ch("|") {
                let s = i
                i += 2
                state.inBlockComment = true
                continueBlockComment(start: s)
            } else if next == ch("{") {
                add(.scheme, i, i + 2)
                i += 2
                state.frames.append(.init(mode: .music, depth: 0, embedded: true))
            } else if next == ch("(") {
                // Vector literal.
                add(.scheme, i, i + 2)
                i += 2
                state.top.depth += 1
            } else {
                lexSchemeAtom()
            }
        case ch("'"), ch("`"), ch(","):
            let s = i
            i += 1
            if c == ch(",") && at(i) == ch("@") { i += 1 }
            add(.scheme, s, i)
        default:
            lexSchemeAtom()
        }
    }

    /// A Scheme atom: symbol, number, boolean, keyword or character literal.
    mutating func lexSchemeAtom() {
        let s = i
        if chars[i] == ch("#") && at(i + 1) == BACKSLASH {
            // Character literal: #\a, #\(, #\space
            i += 2
            if i < n && !isNewline(chars[i]) { i += 1 }
            while i < n && isLetter(chars[i]) { i += 1 }
            add(.scheme, s, i)
            return
        }
        while i < n {
            let c = chars[i]
            if isSpace(c) || isNewline(c) || c == ch("(") || c == ch(")") || c == QUOTE || c == ch(";")
                || c == ch("{") || c == ch("}") {
                break
            }
            // In LilyPond mode a single-atom expression also ends at markup
            // or music syntax: `#red}` or `#3\p`.
            if state.top.mode != .scheme && (c == BACKSLASH || c == ch("|") || c == ch("~")) {
                break
            }
            i += 1
        }
        if i == s { i += 1; return }
        add(isSchemeNumber(s, i) ? .number : .scheme, s, i)
    }

    func isSchemeNumber(_ s: Int, _ e: Int) -> Bool {
        var j = s
        if chars[j] == ch("-") || chars[j] == ch("+") { j += 1 }
        guard j < e else { return false }
        var sawDigit = false
        while j < e {
            let c = chars[j]
            if isDigit(c) {
                sawDigit = true
            } else if c != ch(".") && c != ch("/") {
                return false
            }
            j += 1
        }
        return sawDigit
    }
}
