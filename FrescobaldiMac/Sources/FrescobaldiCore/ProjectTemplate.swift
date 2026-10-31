import Foundation

/// Creates a new multi-file LilyPond project from a `ScoreSpec`, laid out
/// the way larger projects are usually organized: the music in one include
/// file per player, the shared structure (key, time, marks) in one place,
/// titles and page settings shared by the score and the parts, and the
/// score and each part as small files that only put things together.
///
///     <name>.ly              the full score: engrave this
///     header.ily             titles, shared with the parts
///     style.ily              page format and layout, shared with the parts
///     music/global.ily       key, time signature, tempo, rehearsal marks
///     music/<player>.ily     the music, one file per player
///     parts/<player>.ly      one engravable part per player
///
/// Every .ily names the score as its master (`-*- master: ...;`), so
/// engraving any of them engraves the score.
public enum ProjectTemplate {
    /// "My Little Song" → "my-little-song".
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let parts = folded.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return parts.isEmpty ? "score" : parts.joined(separator: "-")
    }

    public static func mainFileName(name: String) -> String { slug(name) + ".ly" }

    /// The files to write, relative to the project folder. `name` is the
    /// project's (the folder's) name, which names the score file; the title
    /// is the spec's, or `name` if it has none.
    public static func files(for spec: ScoreSpec, name: String, version: LilyPondVersion?)
        -> [(path: String, contents: String)] {
        Writer(spec: spec, name: name, version: version).files()
    }
}

private struct Writer {
    let spec: ScoreSpec
    let main: String
    let title: String
    let players: [ResolvedPlayer]
    let version: String
    let language: PitchLanguage
    /// Pianos and organs: their staves are called "right" and "left" unless
    /// there are several.
    let keyboards: Int

    init(spec: ScoreSpec, name: String, version: LilyPondVersion?) {
        self.spec = spec
        main = ProjectTemplate.mainFileName(name: name)
        let title = spec.title.trimmingCharacters(in: .whitespaces)
        self.title = title.isEmpty ? name : title
        players = spec.resolvedPlayers
        self.version = "\\version \"\(version?.description ?? "2.24.0")\""
        language = spec.language
        keyboards = players.filter { $0.instrument.kind == .grand || $0.instrument.kind == .organ }.count
    }

    func files() -> [(path: String, contents: String)] {
        var files = [(main, score()), ("header.ily", header()), ("style.ily", style()), ("music/global.ily", global())]
        for player in players {
            files.append(("music/\(player.file).ily", music(player)))
        }
        if spec.hasParts {
            for player in players where player.instrument.isPlayed {
                files.append(("parts/\(player.file).ly", part(player)))
            }
        }
        return files
    }

    // MARK: Files

    /// `\version`, the master and `\language` lines.
    private func top(master: String?, pitches: Bool = true) -> String {
        var lines = [version]
        if let master { lines.append("% -*- master: \(master);") }
        if pitches && language != .nederlands { lines.append("\\language \"\(language.rawValue)\"") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func score() -> String {
        var text = top(master: nil)
        let column = max(main.count + 2, 20)
        func row(_ file: String, _ what: String) -> String {
            "%   \(file.padding(toLength: column, withPad: " ", startingAt: 0))\(what)\n"
        }
        text += "\n% \(title): the full score. Engrave this file for the score.\n%\n"
        text += row(main, "this file: puts the score together")
        text += row("header.ily", spec.hasParts ? "titles, shared with the parts" : "titles")
        text += row("style.ily", spec.hasParts ? "page format and layout, shared with the parts" : "page format and layout")
        text += row("music/global.ily", "key, time signature, tempo and rehearsal marks")
        text += row("music/<player>.ily", "the music, one file per player")
        if spec.hasParts { text += row("parts/<player>.ly", "one part per player") }
        text += """
            %
            % The .ily files name this file as their master, so engraving any of
            % them in Frescobaldi engraves the score.

            """
        if let note = transpositionNote { text += note }
        text += "\n#(set-global-staff-size \(spec.effectiveScoreStaffSize))\n"
        text += includes(prefix: "", players: players)
        text += "\nfullScore = <<\n"
        for group in groups {
            text += staves(group, indent: 2)
        }
        text += ">>\n\n\\score {\n  \\fullScore\n"
        if spec.effectiveHideEmptyStaves {
            text += """
                  \\layout {
                    % Staves with nothing but rests are left out after the first system.
                    \\context { \\Staff \\RemoveEmptyStaves }
                  }

                """
        } else {
            text += "  \\layout { }\n"
        }
        text += "}\n"
        if spec.midi {
            text += "\n% The MIDI file, with repeats played out.\n\\score {\n  \\unfoldRepeats \\fullScore\n"
            if midiStaves > 15 {
                // MIDI has 16 channels; by default each staff takes one.
                text += """
                      \\midi {
                        % One MIDI channel per instrument, as there are more than 15 staves.
                        \\context { \\Score midiChannelMapping = #'instrument }
                      }

                    """
            } else {
                text += "  \\midi { }\n"
            }
            text += "}\n"
        }
        return text
    }

    /// Staves that play in the MIDI file.
    private var midiStaves: Int {
        players.reduce(0) { count, player in
            switch player.instrument.kind {
            case .grand: count + 2
            case .organ: count + 3
            case .chordNames: count
            default: count + 1
            }
        }
    }

    private var transpositionNote: String? {
        guard players.contains(where: { $0.instrument.transposition != nil }) else { return nil }
        if !spec.concertPitch {
            return comment("""
                Transposing instruments are entered as written (as the players read them); \\transposition \
                in their music makes the MIDI sound right.
                """)
        }
        let shown = spec.transposedScore
            ? "The score and the parts show them as written."
            : "The parts show them as written, the score as they sound (a score in C)."
        var note = comment("""
            Transposing instruments (clarinets, horns, saxophones …) are entered at concert pitch, as \
            they sound. \(shown)
            """)
        if players.contains(where: { $0.instrument.transposesByOctave }) {
            note += comment("Octave transpositions (piccolo, double bass …) are entered as written.")
        }
        return note
    }

    private func includes(prefix: String, players: [ResolvedPlayer]) -> String {
        var text = """
            \\include "\(prefix)style.ily"
            \\include "\(prefix)header.ily"
            \\include "\(prefix)music/global.ily"

            """
        for player in players { text += "\\include \"\(prefix)music/\(player.file).ily\"\n" }
        return text
    }

    private func header() -> String {
        var text = top(master: main, pitches: false)
        text += "\n% Titles, shared by the score and the parts.\n\\header {\n"
        let fields = [("title", title), ("subtitle", spec.subtitle), ("dedication", spec.dedication),
                      ("composer", spec.composer), ("arranger", spec.arranger), ("poet", spec.poet),
                      ("opus", spec.opus), ("copyright", spec.copyright)]
        for (field, value) in fields {
            let value = value.trimmingCharacters(in: .whitespaces)
            // An empty composer shows where it goes.
            if !value.isEmpty || field == "composer" { text += "  \(field) = \(quoted(value))\n" }
        }
        if !spec.tagline { text += "  tagline = ##f\n" }
        return text + "}\n"
    }

    private func style() -> String {
        let paper = spec.paperSize + (spec.landscape ? "landscape" : "")
        return top(master: main, pitches: false) + """

            % Page format and layout, shared by the score and the parts. The staff
            % size is set in each of them, before they include this file.
            \\paper {
              #(set-paper-size \(quoted(paper)))
            }

            \\layout {
              % Settings for the score and every part, for example:
              % \\context { \\Score \\override BarNumber.break-visibility = ##(#f #t #t) }
            }

            """
    }

    private func global() -> String {
        var text = top(master: "../\(main)")
        text += """

            % The structure every player shares: key, time signature, tempo, and the
            % bars as skips. Put rehearsal marks, key and time changes and double
            % bar lines here, at their bar, and every staff gets them.
            global = {

            """
        text += "  \\key \(spec.key.tonic.name(in: language, octaveMarks: false)) \\\(spec.key.mode.rawValue)\n"
        if spec.time.hasSymbol && !spec.time.symbol { text += "  \\numericTimeSignature\n" }
        text += "  \\time \(spec.time.numerator)/\(spec.time.denominator)\n"
        if let tempo = tempoCommand { text += "  \(tempo)\n" }
        if let pickup = spec.pickup { text += "  \\partial \(pickup) s\(pickup) |\n" }
        text += "  s\(bars) |\n}\n"
        return text
    }

    private var tempoCommand: String? {
        let words = spec.tempo.text.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !words.isEmpty { parts.append(quoted(words)) }
        if let beat = spec.tempo.beat { parts.append("\(beat) = \(spec.tempo.bpm)") }
        return parts.isEmpty ? nil : "\\tempo " + parts.joined(separator: " ")
    }

    /// "1*4": the empty bars, for rests and skips.
    private var bars: String {
        spec.time.barDuration + (spec.bars > 1 ? "*\(spec.bars)" : "")
    }

    private func music(_ player: ResolvedPlayer) -> String {
        let instrument = player.instrument
        var text = top(master: "../\(main)") + "\n"
        if let note = musicNote(player) { text += note }
        switch instrument.kind {
        case .grand:
            text += variable(player.variable + "Right", clef: "treble", start: instrument.startPitch, player: player)
            text += "\n" + variable(player.variable + "Left", clef: "bass", start: Pitch(0), player: player)
        case .organ:
            text += variable(player.variable + "Right", clef: "treble", start: instrument.startPitch, player: player)
            text += "\n" + variable(player.variable + "Left", clef: "bass", start: Pitch(0), player: player)
            text += "\n" + variable(player.variable + "Pedal", clef: "bass", start: Pitch(0), player: player)
        case .voice:
            text += variable(player.variable, clef: instrument.clef, start: instrument.startPitch, player: player)
            text += "\n\(player.variable)Words = \\lyricmode {\n\n}\n"
        case .drums, .percussion:
            text += "\(player.variable) = \\drummode {\n\(placeholder(rest: "r", multi: "R"))}\n"
        case .chordNames:
            text += "\(player.variable) = \\chordmode {\n\(placeholder(rest: "s", multi: "s"))}\n"
        case .tablature:
            // The clef is set on the staff, so the tablature keeps its own.
            text += variable(player.variable, clef: nil, start: instrument.startPitch, player: player)
        case .single:
            text += variable(player.variable, clef: instrument.clef, start: instrument.startPitch, player: player)
        }
        return text
    }

    private func musicNote(_ player: ResolvedPlayer) -> String? {
        let instrument = player.instrument
        guard instrument.transposition != nil else { return nil }
        if instrument.transposesByOctave || !spec.concertPitch {
            return comment("\(player.name), entered as written; \\transposition makes the MIDI sound right.") + "\n"
        }
        let shown = spec.transposedScore ? "The score and the part show" : "The part shows"
        return comment("\(player.name), entered at concert pitch (as it sounds). \(shown) it as written.") + "\n"
    }

    /// `name = \relative c'' { … }` with a clef and the empty bars.
    private func variable(_ name: String, clef: String?, start: Pitch, player: ResolvedPlayer) -> String {
        let opening: String
        switch spec.entry {
        case .relative: opening = "\\relative \(start.name(in: language)) {"
        case .fixed: opening = "\\fixed \(start.name(in: language)) {"
        case .absolute: opening = "{"
        }
        var text = "\(name) = \(opening)\n"
        let instrument = player.instrument
        if instrument.transposesByOctave || (instrument.transposesKey && !spec.concertPitch),
           let transposition = instrument.transposition {
            text += "  \\transposition \(transposition.name(in: language))\n"
        }
        if let clef { text += "  \\clef \(clefName(clef))\n" }
        return text + placeholder(rest: "r", multi: "R") + "}\n"
    }

    private func placeholder(rest: String, multi: String) -> String {
        var text = ""
        if let pickup = spec.pickup { text += "  \(rest)\(pickup) |\n" }
        return text + "  \(multi)\(bars) |\n"
    }

    private func clefName(_ clef: String) -> String {
        clef.allSatisfy(\.isLetter) ? clef : quoted(clef)
    }

    private func part(_ player: ResolvedPlayer) -> String {
        var text = top(master: nil)
        text += "\n% The \(player.name) part. The music is in ../music/\(player.file).ily.\n\n"
        text += "#(set-global-staff-size \(spec.partStaffSize))\n"
        text += includes(prefix: "../", players: [player])
        text += "\n\\header {\n  instrument = \(markup(player.name))\n}\n\n"
        text += "\\score {\n  \\compressMMRests <<\n"
        text += staff(player, indent: 4, inScore: false, written: true)
        text += "  >>\n  \\layout { }\n}\n"
        return text
    }

    // MARK: The score's staves

    private enum Group {
        case player(ResolvedPlayer)
        case bracket(choir: Bool, [ResolvedPlayer])
    }

    private var groups: [Group] {
        let staffed = players
        switch spec.grouping {
        case .none:
            return staffed.map { .player($0) }
        case .together:
            guard staffed.filter({ $0.instrument.isPlayed }).count > 1 else { return staffed.map { .player($0) } }
            return [.bracket(choir: staffed.allSatisfy { $0.instrument.family == .voices }, staffed)]
        case .byFamily:
            var groups: [Group] = []
            var run: [ResolvedPlayer] = []
            func flush() {
                if run.count > 1 {
                    groups.append(.bracket(choir: run[0].instrument.family == .voices, run))
                } else {
                    groups += run.map { .player($0) }
                }
                run = []
            }
            for player in staffed {
                let family = player.instrument.family
                let groupable = family != .keyboards && family != .other
                if !groupable || run.first.map({ $0.instrument.family != family }) == true { flush() }
                if groupable { run.append(player) } else { groups.append(.player(player)) }
            }
            flush()
            return groups
        }
    }

    private func staves(_ group: Group, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch group {
        case .player(let player):
            return staff(player, indent: indent, inScore: true, written: spec.transposedScore)
        case .bracket(let choir, let players):
            var text = "\(pad)\\new \(choir ? "ChoirStaff" : "StaffGroup") <<\n"
            for player in players { text += staff(player, indent: indent + 2, inScore: true, written: spec.transposedScore) }
            return text + "\(pad)>>\n"
        }
    }

    /// The staff (or staves) of a player; in the score with names and MIDI
    /// sounds. `written`: transposing instruments as written; otherwise as
    /// they sound, but for octave transpositions.
    private func staff(_ player: ResolvedPlayer, indent: Int, inScore: Bool, written: Bool) -> String {
        let pad = String(repeating: " ", count: indent)
        let instrument = player.instrument
        let v = player.variable
        var properties: [String] = []
        if inScore && spec.instrumentNames != .none {
            properties.append("instrumentName = \(markup(player.name))")
            if spec.instrumentNames == .fullThenShort {
                properties.append("shortInstrumentName = \(markup(player.shortName))")
            }
        }
        let midi = inScore ? ["midiInstrument = \(quoted(instrument.midi))"] : []

        switch instrument.kind {
        case .grand, .organ:
            let ids = keyboards > 1 ? (v + "Right", v + "Left", v + "Pedal") : ("right", "left", "pedal")
            var text = "\(pad)\\new PianoStaff\(with(properties, pad))<<\n"
            text += "\(pad)  \\new Staff = \"\(ids.0)\"\(inline(midi))<< \\global \\\(v)Right >>\n"
            text += "\(pad)  \\new Staff = \"\(ids.1)\"\(inline(midi))<< \\global \\\(v)Left >>\n"
            text += "\(pad)>>\n"
            if instrument.kind == .organ {
                text += "\(pad)\\new Staff = \"\(ids.2)\"\(inline(midi))<< \\global \\\(v)Pedal >>\n"
            }
            return text
        case .voice:
            return "\(pad)\\new Staff\(with(properties + midi, pad))\\new Voice = \"\(v)\" << \\global \\\(v) >>\n"
                + "\(pad)\\new Lyrics \\lyricsto \"\(v)\" \\\(v)Words\n"
        case .drums:
            return "\(pad)\\new DrumStaff\(with(properties, pad))<< \\global \\\(v) >>\n"
        case .percussion:
            let percussion = ["drumStyleTable = #percussion-style", "\\override StaffSymbol.line-count = #1"]
            return "\(pad)\\new DrumStaff\(with(percussion + properties, pad))<< \\global \\\(v) >>\n"
        case .chordNames:
            return "\(pad)\\new ChordNames \\\(v)\n"
        case .tablature:
            var text = "\(pad)\\new StaffGroup\(with(properties, pad))<<\n"
            text += "\(pad)  \\new Staff\(inline(midi)){ \\clef \(clefName(instrument.clef)) << \\global \\\(v) >> }\n"
            text += "\(pad)  \\new TabStaff \\with { \\remove \"Staff_performer\" } << \\global \\\(v) >>\n"
            return text + "\(pad)>>\n"
        case .single:
            return "\(pad)\\new Staff\(with(properties + midi, pad))\(transposed(player, written: written))\n"
        }
    }

    /// The music of a one-staff player, transposed for the staff.
    private func transposed(_ player: ResolvedPlayer, written: Bool) -> String {
        let instrument = player.instrument
        let music = "<< \\global \\\(player.variable) >>"
        guard instrument.transposesKey, let transposition = instrument.transposition else { return music }
        if !spec.concertPitch {
            // Entered as written; only the key from \global needs transposing.
            return "<< \\transpose \(name(spelled(transposition))) \(name(.middleC)) \\global \\\(player.variable) >>"
        }
        // Entered at concert pitch: transpose the staff, and tell the MIDI how
        // the shown notes sound.
        var shown = transposition
        if !written {
            // A score in C keeps the octave of the transposition (tenor saxophone).
            let octaves = Int((Double(transposition.semitones) / 12).rounded(.towardZero))
            shown = Pitch(0, octave: 1 + octaves)
            if shown == .middleC { return music }
        }
        let from = shown.fifths == 0 ? shown : spelled(shown)
        return "{ \\transposition \(name(shown)) \\transpose \(name(from)) \(name(.middleC)) \(music) }"
    }

    /// The transposition spelled so the written key has at most six sharps or
    /// flats: a B♭ clarinet in concert B major reads D♭ major, not C♯ major.
    private func spelled(_ transposition: Pitch) -> Pitch {
        let written = spec.key.fifths - transposition.fifths
        if written > 6 { return .at(fifths: transposition.fifths + 12, near: transposition) }
        if written < -6 { return .at(fifths: transposition.fifths - 12, near: transposition) }
        return transposition
    }

    private func name(_ pitch: Pitch) -> String { pitch.name(in: language) }

    /// ` \with { … } ` on one line, or a space if there's nothing.
    private func inline(_ properties: [String]) -> String {
        properties.isEmpty ? " " : " \\with { \(properties.joined(separator: " ")) } "
    }

    /// ` \with { … } ` on separate lines, or a space if there's nothing.
    private func with(_ properties: [String], _ pad: String) -> String {
        guard !properties.isEmpty else { return " " }
        return " \\with {\n" + properties.map { "\(pad)  \($0)\n" }.joined() + "\(pad)} "
    }

    // MARK: Strings

    /// `text` as comment lines of at most 76 characters.
    private func comment(_ text: String) -> String {
        var lines: [String] = []
        var line = "%"
        for word in text.split(separator: " ") {
            if line.count + 1 + word.count > 76 && line != "%" {
                lines.append(line)
                line = "%"
            }
            line += " " + word
        }
        lines.append(line)
        return lines.joined(separator: "\n") + "\n"
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A string, or a markup with LilyPond's own flat and sharp signs
    /// ("Clarinet in B♭").
    private func markup(_ text: String) -> String {
        guard text.contains(where: { $0 == "♭" || $0 == "♯" }) else { return quoted(text) }
        var pieces: [String] = []
        var run = ""
        for character in text {
            if character == "♭" || character == "♯" {
                if !run.isEmpty { pieces.append(quoted(run)) }
                run = ""
                pieces.append("\\hspace #0.2 \\fontsize #-2 \\raise #0.5 \\\(character == "♭" ? "flat" : "sharp")")
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty { pieces.append(quoted(run)) }
        return "\\markup \\concat { \(pieces.joined(separator: " ")) }"
    }
}
