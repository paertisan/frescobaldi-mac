import Foundation
import FrescobaldiCore

/// The `new_score` tool: the Score Wizard's settings as tool arguments.
enum NewScoreArguments {
    static let papers = ["a4", "letter", "a3", "tabloid", "b4", "legal"]

    static let schema: JSONValue = FrescobaldiTools.schema([
        "path": FrescobaldiTools.string("The project folder to create; it must not exist, or be empty. Its name names the score file."),
        "ensemble": FrescobaldiTools.string("A preset ensemble: its players, brackets and usual settings.",
                                            oneOf: Ensemble.all.map(\.id)),
        "instruments": [
            "type": "array",
            "description": """
                The players in score order, instead of or on top of `ensemble`. Repeat an instrument for \
                several players: violin twice gives Violin I and II.
                """,
            "items": FrescobaldiTools.string("Instrument", oneOf: Instrument.all.map(\.id)),
        ],
        "names": [
            "type": "array",
            "description": "Names for the players, in the same order; empty strings keep the usual names.",
            "items": ["type": "string"],
        ],
        "title": FrescobaldiTools.string("Title (default: the folder's name)."),
        "subtitle": FrescobaldiTools.string("Subtitle."),
        "composer": FrescobaldiTools.string("Composer."),
        "arranger": FrescobaldiTools.string("Arranger."),
        "poet": FrescobaldiTools.string("Author of the words."),
        "opus": FrescobaldiTools.string("Opus, such as \"Op. 12\"."),
        "dedication": FrescobaldiTools.string("Dedication."),
        "copyright": FrescobaldiTools.string("Copyright line."),
        "tagline": FrescobaldiTools.boolean("Keep LilyPond's \"Music engraving by LilyPond\" line (default false)."),
        "key": FrescobaldiTools.string("Key, such as \"ees major\", \"fis minor\" or \"d dorian\" (default c major)."),
        "time": FrescobaldiTools.string("Time signature, such as 3/4 or 6/8; C and ¢ for the symbols (default C)."),
        "pickup": FrescobaldiTools.string("Pickup (\\partial) duration.", oneOf: TimeSignature.pickups),
        "bars": FrescobaldiTools.integer("Empty bars to start with (default 4).", minimum: 1, maximum: 64),
        "tempo": FrescobaldiTools.string("Tempo words, such as Allegro."),
        "metronome": FrescobaldiTools.string("Metronome mark, such as \"4 = 120\" or \"4. = 60\"."),
        "language": FrescobaldiTools.string("Pitch names in the music (default nederlands).",
                                            oneOf: PitchLanguage.allCases.map(\.rawValue)),
        "entry": FrescobaldiTools.string("How octaves are entered (default relative).",
                                         oneOf: EntryMode.allCases.map(\.rawValue)),
        "concert_pitch": FrescobaldiTools.boolean("""
            Enter transposing instruments at concert pitch (default true); false enters them as written.
            """),
        "transposed_score": FrescobaldiTools.boolean("""
            With concert pitch: the score shows transposing instruments as written (default true) or as they \
            sound (false, a score in C). Parts are always as written.
            """),
        "paper": FrescobaldiTools.string("Paper size (default a4).", oneOf: papers),
        "landscape": FrescobaldiTools.boolean("Landscape paper (default false)."),
        "staff_size": FrescobaldiTools.integer("Staff size of the score in points (default: from the number of staves).",
                                               minimum: 10, maximum: 30),
        "parts": FrescobaldiTools.boolean("Make a part for each player (default true, false for choirs)."),
        "part_staff_size": FrescobaldiTools.integer("Staff size of the parts (default 20).", minimum: 10, maximum: 30),
        "instrument_names": FrescobaldiTools.string("Instrument names on the systems.",
                                                    oneOf: InstrumentNames.allCases.map(\.rawValue)),
        "brackets": FrescobaldiTools.string("Brackets around the staves (default byFamily).",
                                            oneOf: Grouping.allCases.map(\.rawValue)),
        "hide_empty_staves": FrescobaldiTools.boolean("Leave out staves with only rests after the first system (default: from eight staves)."),
        "midi": FrescobaldiTools.boolean("Write a MIDI file (default true)."),
        "piano_tables": FrescobaldiTools.boolean("Type pianos as tables (\\pianoTable: both staves in the right hand's music, with cross-staff beams); writes piano-tables.ily into the project. Default false, true for the piano-tables ensemble."),
        "open": FrescobaldiTools.boolean("Open the score in Frescobaldi if it's running (default true)."),
    ], required: ["path"])

    static func spec(_ arguments: JSONValue) throws -> ScoreSpec {
        var spec = ScoreSpec()
        if let id = arguments["ensemble"]?.string {
            guard let ensemble = Ensemble.named(id) else {
                throw MCPToolError("No ensemble \(id). Ensembles: \(Ensemble.all.map(\.id).joined(separator: ", ")).")
            }
            spec.apply(ensemble)
        }
        if let list = arguments["instruments"]?.array {
            let ids = list.compactMap(\.string)
            let unknown = ids.filter { Instrument.named($0) == nil }
            guard unknown.isEmpty else {
                throw MCPToolError("Unknown instruments: \(unknown.joined(separator: ", ")). Instruments: \(Instrument.all.map(\.id).joined(separator: ", ")).")
            }
            spec.players = ids.map { Player(instrument: $0) }
            if arguments["ensemble"] == nil && spec.playedCount < 2 { spec.instrumentNames = .none }
        }
        guard !spec.players.isEmpty else { throw MCPToolError("Give `ensemble` or `instruments`.") }
        for (index, name) in (arguments["names"]?.array ?? []).enumerated() where index < spec.players.count {
            if let name = name.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty { spec.players[index].name = name }
        }

        spec.title = arguments["title"]?.string ?? ""
        spec.subtitle = arguments["subtitle"]?.string ?? ""
        spec.composer = arguments["composer"]?.string ?? ""
        spec.arranger = arguments["arranger"]?.string ?? ""
        spec.poet = arguments["poet"]?.string ?? ""
        spec.opus = arguments["opus"]?.string ?? ""
        spec.dedication = arguments["dedication"]?.string ?? ""
        spec.copyright = arguments["copyright"]?.string ?? ""
        spec.tagline = arguments["tagline"]?.bool ?? false

        if let key = arguments["key"]?.string { spec.key = try self.key(key) }
        if let time = arguments["time"]?.string { spec.time = try self.time(time) }
        if let pickup = arguments["pickup"]?.string {
            guard TimeSignature.pickups.contains(pickup), spec.time.fits(pickup: pickup) else {
                throw MCPToolError("A pickup of \(pickup) doesn't fit: it must be one of \(TimeSignature.pickups.joined(separator: ", ")) and shorter than a bar.")
            }
            spec.pickup = pickup
        }
        if let bars = arguments["bars"]?.int { spec.bars = min(64, max(1, bars)) }
        spec.tempo.text = arguments["tempo"]?.string ?? ""
        if let mark = arguments["metronome"]?.string {
            let parts = mark.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let bpm = Int(parts[1]), bpm > 0, let base = Int(parts[0].filter(\.isNumber)),
                  [1, 2, 4, 8, 16].contains(base), parts[0].allSatisfy({ $0.isNumber || $0 == "." }) else {
                throw MCPToolError("Write the metronome mark as beat = number, such as \"4 = 120\" or \"4. = 60\".")
            }
            spec.tempo.beat = parts[0]
            spec.tempo.bpm = bpm
        }

        if let name = arguments["language"]?.string {
            guard let language = PitchLanguage(rawValue: name) else {
                throw MCPToolError("Unknown language \(name). Languages: \(PitchLanguage.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            spec.language = language
        }
        if let name = arguments["entry"]?.string {
            guard let entry = EntryMode(rawValue: name) else { throw MCPToolError("entry is relative, fixed or absolute.") }
            spec.entry = entry
        }
        spec.concertPitch = arguments["concert_pitch"]?.bool ?? true
        spec.transposedScore = arguments["transposed_score"]?.bool ?? true

        if let paper = arguments["paper"]?.string {
            guard papers.contains(paper) else { throw MCPToolError("Paper sizes: \(papers.joined(separator: ", ")).") }
            spec.paperSize = paper
        }
        spec.landscape = arguments["landscape"]?.bool ?? false
        if let size = arguments["staff_size"]?.int { spec.scoreStaffSize = min(30, max(10, size)) }
        if let size = arguments["part_staff_size"]?.int { spec.partStaffSize = min(30, max(10, size)) }
        if let parts = arguments["parts"]?.bool { spec.makeParts = parts }
        if let name = arguments["instrument_names"]?.string {
            guard let names = InstrumentNames(rawValue: name) else {
                throw MCPToolError("instrument_names is \(InstrumentNames.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            spec.instrumentNames = names
        }
        if let name = arguments["brackets"]?.string {
            guard let grouping = Grouping(rawValue: name) else {
                throw MCPToolError("brackets is \(Grouping.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            spec.grouping = grouping
        }
        if let hide = arguments["hide_empty_staves"]?.bool { spec.hideEmptyStaves = hide }
        spec.midi = arguments["midi"]?.bool ?? true
        if let tables = arguments["piano_tables"]?.bool { spec.pianoTables = tables }
        return spec
    }

    /// "ees major", "fis minor", "Eb major", "F# minor".
    static func key(_ text: String) throws -> KeySignature {
        let words = text.split(separator: " ").map(String.init)
        guard (1...2).contains(words.count) else { throw MCPToolError("Write the key as tonic and mode, such as \"ees major\".") }
        let mode = words.count == 2 ? words[1].lowercased() : "major"
        let modes = ["ionian": KeySignature.Mode.major, "aeolian": .minor]
        guard let keyMode = KeySignature.Mode(rawValue: mode) ?? modes[mode] else {
            throw MCPToolError("Unknown mode \(mode). Modes: \(KeySignature.Mode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let tonic = pitch(words[0]) else { throw MCPToolError("\(words[0]) isn't a note name; use c, fis, bes or Eb.") }
        let key = KeySignature(tonic: Pitch(tonic.step, tonic.alteration), mode: keyMode)
        guard abs(key.fifths) <= 7 else { throw MCPToolError("\(text) has more than seven sharps or flats.") }
        return key
    }

    private static func pitch(_ name: String) -> Pitch? {
        if let pitch = Pitch(name.lowercased()), !name.contains(where: { $0 == "'" || $0 == "," }) { return pitch }
        // Eb, F#, B♭
        guard let letter = name.first?.lowercased(), let step = "cdefgab".firstIndex(of: Character(letter)) else { return nil }
        let rest = name.dropFirst()
        guard rest.allSatisfy({ "b#♭♯".contains($0) }), rest.count <= 2 else { return nil }
        let alteration = rest.reduce(0) { $0 + ($1 == "#" || $1 == "♯" ? 1 : -1) }
        return Pitch("cdefgab".distance(from: "cdefgab".startIndex, to: step), alteration)
    }

    static func time(_ text: String) throws -> TimeSignature {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text == "C" { return TimeSignature(4, 4) }
        if text == "¢" || text == "C|" { return TimeSignature(2, 2) }
        let parts = text.split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) else {
            throw MCPToolError("Write the time signature as 3/4, or C or ¢.")
        }
        let time = TimeSignature(n, d, symbol: false)
        guard time.isValid else { throw MCPToolError("\(text) isn't a time signature LilyPond can write.") }
        return time
    }
}
