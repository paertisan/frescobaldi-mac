import Foundation
import Testing
@testable import FrescobaldiCore

/// `(kind, text)` pairs for compact expectations.
private func lexed(_ source: String) -> [(LilyTokenKind, String)] {
    let ns = source as NSString
    return LilyPondLexer.tokens(in: source).map { ($0.kind, ns.substring(with: $0.range)) }
}

private func kinds(of word: String, in source: String) -> [LilyTokenKind] {
    lexed(source).filter { $0.1 == word }.map(\.0)
}

private func expectTokens(_ source: String, _ expected: [(LilyTokenKind, String)],
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let actual = lexed(source)
    let a = actual.map { "\($0.0.rawValue) \($0.1)" }
    let e = expected.map { "\($0.0.rawValue) \($0.1)" }
    #expect(a == e, sourceLocation: sourceLocation)
}

@Suite struct LilyPondLexerTests {
    @Test func simpleMusic() {
        expectTokens(#"\relative c' { cis4 d8. r16 | e2~ e }"#, [
            (.command, #"\relative"#), (.pitch, "c'"), (.delimiter, "{"),
            (.pitch, "cis"), (.duration, "4"), (.pitch, "d"), (.duration, "8"), (.duration, "."),
            (.rest, "r"), (.duration, "16"), (.barCheck, "|"),
            (.pitch, "e"), (.duration, "2"), (.spanner, "~"), (.pitch, "e"), (.delimiter, "}"),
        ])
    }

    @Test func pitchDecorations() {
        expectTokens("c''!4 bes,? fis='' q8", [
            (.pitch, "c''!"), (.duration, "4"), (.pitch, "bes,?"), (.pitch, "fis=''"),
            (.pitch, "q"), (.duration, "8"),
        ])
    }

    @Test func pitchLanguages() {
        for name in ["asas", "h", "heses", "cs", "css", "dob", "solss", "cflat", "c-sharp", "eeh", "fisis"] {
            #expect(kinds(of: name, in: "{ \(name)4 }") == [.pitch], "\(name)")
        }
        // Not a note name in any language.
        #expect(kinds(of: "treble", in: #"\clef treble"#) == [])
    }

    @Test func chordsAndRests() {
        expectTokens("<c e g>2. R1*4 s4 \\skip 8", [
            (.delimiter, "<"), (.pitch, "c"), (.pitch, "e"), (.pitch, "g"), (.delimiter, ">"),
            (.duration, "2"), (.duration, "."), (.rest, "R"), (.duration, "1"), (.duration, "*4"),
            (.rest, "s"), (.duration, "4"), (.rest, #"\skip"#), (.duration, "8"),
        ])
    }

    @Test func numbersVersusDurations() {
        #expect(kinds(of: "3/4", in: #"\time 3/4"#) == [.number])
        #expect(kinds(of: "8", in: #"\partial 8"#) == [.duration])
        #expect(kinds(of: "2", in: #"\repeat volta 2 { c }"#) == [.number])
        #expect(lexed(#"\tuplet 3/2 4 { c8 d e }"#).filter { $0.0 == .duration || $0.0 == .number }.map(\.1)
                == ["3/2", "4", "8"])
        #expect(kinds(of: "120", in: #"\tempo 4 = 120"#) == [.number])
        #expect(kinds(of: ":16", in: "c4:16") == [.duration])
        #expect(kinds(of: #"\breve"#, in: #"c\breve"#) == [.duration])
        #expect(kinds(of: "4", in: "c\n4") == [.duration], "afterMusicItem survives a line break")
    }

    @Test func dynamicsAndArticulations() {
        expectTokens(#"c4\p-. d-> e^\fermata f_3 g\< a\! b\ff\staccato c\3"#, [
            (.pitch, "c"), (.duration, "4"), (.dynamic, #"\p"#), (.articulation, "-."),
            (.pitch, "d"), (.articulation, "->"),
            (.pitch, "e"), (.articulation, "^"), (.articulation, #"\fermata"#),
            (.pitch, "f"), (.articulation, "_3"),
            (.pitch, "g"), (.dynamic, #"\<"#), (.pitch, "a"), (.dynamic, #"\!"#),
            (.pitch, "b"), (.dynamic, #"\ff"#), (.articulation, #"\staccato"#),
            (.pitch, "c"), (.articulation, #"\3"#),
        ])
    }

    @Test func spanners() {
        expectTokens(#"c( d) e\( f\) g[ a] b\[ c\]"#, [
            (.pitch, "c"), (.spanner, "("), (.pitch, "d"), (.spanner, ")"),
            (.pitch, "e"), (.spanner, #"\("#), (.pitch, "f"), (.spanner, #"\)"#),
            (.pitch, "g"), (.spanner, "["), (.pitch, "a"), (.spanner, "]"),
            (.pitch, "b"), (.spanner, #"\["#), (.pitch, "c"), (.spanner, #"\]"#),
        ])
    }

    @Test func keywordsCommandsVariables() {
        expectTokens(#"\score { \new Staff \melody \layout { } }"#, [
            (.keyword, #"\score"#), (.delimiter, "{"), (.command, #"\new"#), (.contextName, "Staff"),
            (.variable, #"\melody"#), (.keyword, #"\layout"#), (.delimiter, "{"), (.delimiter, "}"),
            (.delimiter, "}"),
        ])
        #expect(kinds(of: #"\Staff"#, in: #"\layout { \context { \Staff } }"#) == [.contextName])
        #expect(kinds(of: #"\\"#, in: #"<< { c } \\ { d } >>"#) == [.delimiter])
        #expect(kinds(of: #"\major"#, in: #"\key d \major"#) == [.command])
    }

    @Test func assignments() {
        expectTokens("melody = \\relative { c }\n\\header { title = \"T\" }", [
            (.variable, "melody"), (.delimiter, "="), (.command, #"\relative"#), (.delimiter, "{"),
            (.pitch, "c"), (.delimiter, "}"),
            (.keyword, #"\header"#), (.delimiter, "{"), (.property, "title"), (.delimiter, "="),
            (.string, "\"T\""), (.delimiter, "}"),
        ])
        // `\new Staff = "up"` names a context, it isn't an assignment.
        #expect(kinds(of: "Staff", in: #"\new Staff = "up" { c }"#) == [.contextName])
    }

    @Test func properties() {
        expectTokens(#"\set Staff.instrumentName = "Vln""#, [
            (.keyword, #"\set"#), (.contextName, "Staff"), (.property, "instrumentName"),
            (.delimiter, "="), (.string, "\"Vln\""),
        ])
        expectTokens(#"\override Staff.TimeSignature.break-visibility = ##f"#, [
            (.keyword, #"\override"#), (.contextName, "Staff"), (.property, "TimeSignature"),
            (.property, "break-visibility"), (.delimiter, "="), (.scheme, "#"), (.scheme, "#f"),
        ])
        expectTokens(#"\once \override NoteHead.color = #red c"#, [
            (.keyword, #"\once"#), (.keyword, #"\override"#), (.property, "NoteHead"), (.property, "color"),
            (.delimiter, "="), (.scheme, "#"), (.scheme, "red"), (.pitch, "c"),
        ])
    }

    @Test func comments() {
        expectTokens("c % note\n%{ block\nstill %} d", [
            (.pitch, "c"), (.comment, "% note"), (.comment, "%{ block"), (.comment, "still %}"),
            (.pitch, "d"),
        ])
    }

    @Test func strings() {
        expectTokens(#"\bar "|." "a\"b" "multi"#, [
            (.command, #"\bar"#), (.string, "\"|.\""), (.string, #""a\"b""#), (.string, "\"multi"),
        ])
        let state = LilyPondLexer.lex("\"open" as NSString, range: NSRange(location: 0, length: 5))
        #expect(state.inString)
    }

    @Test func lyrics() {
        expectTokens(#"\addlyrics { Hel -- lo __ world4 _ | \set stanza = "1." }"#, [
            (.command, #"\addlyrics"#), (.delimiter, "{"), (.lyricText, "Hel"), (.spanner, "--"),
            (.lyricText, "lo"), (.spanner, "__"), (.lyricText, "world"), (.duration, "4"),
            (.lyricText, "_"), (.barCheck, "|"), (.keyword, #"\set"#), (.property, "stanza"),
            (.delimiter, "="), (.string, "\"1.\""), (.delimiter, "}"),
        ])
        // After the lyrics block we're back in note mode.
        #expect(kinds(of: "d", in: #"\lyricmode { a b } d"#) == [.pitch])
        #expect(kinds(of: "Grüß", in: #"\lyricsto "v" { Grüß dich }"#) == [.lyricText])
    }

    @Test func markup() {
        expectTokens(#"\markup \bold { Hello \italic world } c"#, [
            (.command, #"\markup"#), (.command, #"\bold"#), (.delimiter, "{"), (.markupText, "Hello"),
            (.command, #"\italic"#), (.markupText, "world"), (.delimiter, "}"), (.pitch, "c"),
        ])
        expectTokens(#"\markup hi c"#, [(.command, #"\markup"#), (.markupText, "hi"), (.pitch, "c")])
        expectTokens(#"\markup "x" c"#, [(.command, #"\markup"#), (.string, "\"x\""), (.pitch, "c")])
        #expect(kinds(of: "3", in: #"\markup { 3 }"#) == [.markupText])
    }

    @Test func scheme() {
        expectTokens(#"#(set-global-staff-size 20.5) c"#, [
            (.scheme, "#("), (.scheme, "set-global-staff-size"), (.number, "20.5"), (.scheme, ")"),
            (.pitch, "c"),
        ])
        expectTokens("#(define (f x)\n  ; comment\n  \"s\" #t) d", [
            (.scheme, "#("), (.scheme, "define"), (.scheme, "("), (.scheme, "f"), (.scheme, "x"),
            (.scheme, ")"), (.comment, "; comment"), (.string, "\"s\""), (.scheme, "#t"), (.scheme, ")"),
            (.pitch, "d"),
        ])
        expectTokens(#"#'(1 . 2) $x"#, [
            (.scheme, "#'("), (.number, "1"), (.scheme, "."), (.number, "2"), (.scheme, ")"),
            (.scheme, "$"), (.scheme, "x"),
        ])
        expectTokens(#"#(define m #{ c4 #}) e"#, [
            (.scheme, "#("), (.scheme, "define"), (.scheme, "m"), (.scheme, "#{"), (.pitch, "c"),
            (.duration, "4"), (.scheme, "#}"), (.scheme, ")"), (.pitch, "e"),
        ])
        expectTokens(#"#(display #\() f"#, [
            (.scheme, "#("), (.scheme, "display"), (.scheme, #"#\("#), (.scheme, ")"), (.pitch, "f"),
        ])
        // Block comments only exist inside Scheme.
        expectTokens("#(a #| x\n y |# b) g", [
            (.scheme, "#("), (.scheme, "a"), (.comment, "#| x"), (.comment, " y |#"), (.scheme, "b"),
            (.scheme, ")"), (.pitch, "g"),
        ])
    }

    @Test func drums() {
        #expect(kinds(of: "bd", in: #"\drummode { bd4 sn }"#) == [.pitch])
        #expect(kinds(of: "bd", in: "{ bd4 }") == [])
    }

    @Test func utf16Ranges() {
        let source = "\\markup { 🎵 Grüße } c"
        let ns = source as NSString
        let tokens = LilyPondLexer.tokens(in: source)
        let texts = tokens.map { ns.substring(with: $0.range) }
        #expect(texts == [#"\markup"#, "{", "🎵", "Grüße", "}", "c"])
    }

    @Test func lexesSubrangeWithAbsoluteOffsets() {
        let source = "% header\nc4 d\n" as NSString
        let line2 = source.lineRange(for: NSRange(location: 9, length: 0))
        var tokens: [LilyToken] = []
        LilyPondLexer.lex(source, range: line2) { tokens.append($0) }
        #expect(tokens.map { source.substring(with: $0.range) } == ["c", "4", "d"])
        #expect(tokens.allSatisfy { NSLocationInRange($0.range.location, line2) })
    }

    @Test func edgeCasesAtEndOfText() {
        for source in ["\\", "#", "$", "%{", "\"", "c-", "c:", "#'", "#(", "\\markup", "R1*", "1/", "-", "#\\"] {
            let tokens = LilyPondLexer.tokens(in: source)
            #expect(tokens.allSatisfy { $0.range.length > 0 && NSMaxRange($0.range) <= (source as NSString).length },
                    "\(source)")
        }
    }

    @Test func templatesLexWithoutLeftoverState() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Templates")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ly" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8) as NSString
            let end = LilyPondLexer.lex(text, range: NSRange(location: 0, length: text.length))
            #expect(end.frames.count == 1 && end.top.depth == 0 && !end.inString && !end.inBlockComment,
                    "\(file.lastPathComponent)")
            try checkInvariants(text as String)
        }
    }

    /// Random input made from LilyPond-ish fragments and raw characters.
    @Test(arguments: 0..<300)
    func fuzzInvariants(seed: Int) throws {
        var rng = SplitMix64(seed: UInt64(seed))
        let fragments = [
            "c", "d'", "es,", "4", "8.", "r", "R1*2", "{", "}", "<<", ">>", "<", ">", "\\\\", "|", "~", "(", ")",
            "[", "]", "-.", "^\\fermata", "_3", "\\p", "\\<", "\\!", "\"", "\"str\"", "\\\"", "%", "%{", "%}",
            "%%", "#", "#(", ")", "#{", "#}", "#|", "|#", ";", "$", "'", "`", ",@", "#\\(", "\\markup",
            "\\bold", "\\lyricmode", "\\addlyrics", "\\drummode", "\\set", "\\override", "Staff", ".", "=",
            "name", "--", "__", "\\relative", "\\tuplet", "3/2", ":16", "\\new", "Voice", "🎵", "ü", "\t",
            " ", " ", " ", "\n", "\n", "\r\n", "\\", "-", "x", "\\time", "\u{2028}", "\u{85}", "\r",
        ]
        var source = ""
        for _ in 0..<Int.random(in: 1...120, using: &rng) {
            if Int.random(in: 0..<10, using: &rng) == 0 {
                source.unicodeScalars.append(Unicode.Scalar(UInt8.random(in: 32...126, using: &rng)))
            } else {
                source += fragments.randomElement(using: &rng)!
            }
        }
        try checkInvariants(source)
    }
}

/// Every token in range, non-empty, ordered, within one line; lexing line by
/// line from saved states gives exactly the tokens of a single pass.
private func checkInvariants(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let text = source as NSString
    let whole = NSRange(location: 0, length: text.length)
    var single: [LilyToken] = []
    let endState = LilyPondLexer.lex(text, range: whole) { single.append($0) }

    var previousEnd = 0
    for token in single {
        #expect(token.range.length > 0, sourceLocation: sourceLocation)
        #expect(token.range.location >= previousEnd, "overlap in \(source.debugDescription)",
                sourceLocation: sourceLocation)
        #expect(NSMaxRange(token.range) <= text.length, sourceLocation: sourceLocation)
        let tokenText = text.substring(with: token.range)
        #expect(tokenText.unicodeScalars.allSatisfy { !"\n\r\u{2028}\u{2029}\u{85}".unicodeScalars.contains($0) },
                "token crosses a line: \(tokenText.debugDescription)", sourceLocation: sourceLocation)
        previousEnd = NSMaxRange(token.range)
    }

    // Line by line, split the way NSString splits lines (the editor's checkpoints).
    var lineByLine: [LilyToken] = []
    var state = LilyLexerState.initial
    var location = 0
    while location < text.length {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        state = LilyPondLexer.lex(text, range: line, from: state) { lineByLine.append($0) }
        location = NSMaxRange(line)
    }
    #expect(lineByLine == single, "resume mismatch in \(source.debugDescription)", sourceLocation: sourceLocation)
    #expect(state == endState, sourceLocation: sourceLocation)
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
