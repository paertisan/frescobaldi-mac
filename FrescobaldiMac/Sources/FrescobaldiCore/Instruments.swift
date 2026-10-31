import Foundation

/// A pitch as LilyPond writes it: `step` c = 0 … b = 6, `alteration` in
/// half steps, `octave` as LilyPond counts it (c = 0, c' = 1, c, = -1).
public struct Pitch: Hashable, Codable, Sendable, CustomStringConvertible {
    public var step: Int
    public var alteration: Int
    public var octave: Int

    public init(_ step: Int, _ alteration: Int = 0, octave: Int = 0) {
        self.step = step
        self.alteration = alteration
        self.octave = octave
    }

    /// Parses Dutch names with octave marks: "c", "bes,", "fis''", "ees".
    public init?(_ name: String) {
        guard let first = name.first, let step = "cdefgab".firstIndex(of: first) else { return nil }
        var rest = name.dropFirst()
        var alteration = 0
        while rest.hasPrefix("is") { alteration += 1; rest = rest.dropFirst(2) }
        if (first == "e" || first == "a") && rest.hasPrefix("es") { alteration -= 1; rest = rest.dropFirst(2) }
        while rest.hasPrefix("es") { alteration -= 1; rest = rest.dropFirst(2) }
        guard rest.allSatisfy({ $0 == "'" || $0 == "," }) else { return nil }
        self.init("cdefgab".distance(from: "cdefgab".startIndex, to: step), alteration,
                  octave: rest.filter { $0 == "'" }.count - rest.filter { $0 == "," }.count)
    }

    public static let middleC = Pitch(0, octave: 1)

    /// Half steps above c'.
    public var semitones: Int { (octave - 1) * 12 + [0, 2, 4, 5, 7, 9, 11][step] + alteration }

    /// Place on the line of fifths: c = 0, g = 1, f = -1, bes = -2.
    public var fifths: Int { [0, 2, 4, -1, 1, 3, 5][step] + 7 * alteration }

    /// The pitch at `fifths` on the line of fifths, in the octave nearest `near`.
    public static func at(fifths: Int, near: Pitch) -> Pitch {
        let n = fifths + 1
        let alteration = Int((Double(n) / 7).rounded(.down))
        let step = [3, 0, 4, 1, 5, 2, 6][n - alteration * 7]
        var pitch = Pitch(step, alteration, octave: near.octave)
        pitch.octave += Int((Double(near.semitones - pitch.semitones) / 12).rounded())
        return pitch
    }

    /// The name in Dutch with octave marks, as LilyPond's default language.
    public var description: String { name(in: .nederlands) }

    public func name(in language: PitchLanguage, octaveMarks: Bool = true) -> String {
        var name = language.noteName(step: step, alteration: alteration)
        if octaveMarks {
            name += String(repeating: "'", count: max(0, octave)) + String(repeating: ",", count: max(0, -octave))
        }
        return name
    }
}

/// The pitch-name languages LilyPond knows (`\language`), the common ones.
public enum PitchLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case nederlands, english, deutsch, italiano, français, español
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nederlands: "Dutch (c cis bes)"
        case .english: "English (c cs bf)"
        case .deutsch: "German (c cis b h)"
        case .italiano: "Italian (do dod sib)"
        case .français: "French (do dod sib)"
        case .español: "Spanish (do dos sib)"
        }
    }

    func noteName(step: Int, alteration: Int) -> String {
        switch self {
        case .nederlands:
            // ees and aes, which LilyPond also accepts, read more clearly than es and as.
            return ["c", "d", "e", "f", "g", "a", "b"][step]
                + String(repeating: alteration > 0 ? "is" : "es", count: abs(alteration))
        case .deutsch:
            switch (step, alteration) {
            case (6, -1): return "b"
            case (6, -2): return "heses"
            case (2, ..<0): return String(repeating: "es", count: -alteration)
            case (5, ..<0): return String(repeating: "as", count: -alteration)
            default:
                return ["c", "d", "e", "f", "g", "a", "h"][step]
                    + String(repeating: alteration > 0 ? "is" : "es", count: abs(alteration))
            }
        case .english:
            return ["c", "d", "e", "f", "g", "a", "b"][step] + String(repeating: alteration > 0 ? "s" : "f", count: abs(alteration))
        case .italiano, .français:
            let base = ["do", "re", "mi", "fa", "sol", "la", "si"][step]
            return (self == .français && step == 1 ? "ré" : base)
                + String(repeating: alteration > 0 ? "d" : "b", count: abs(alteration))
        case .español:
            return ["do", "re", "mi", "fa", "sol", "la", "si"][step] + String(repeating: alteration > 0 ? "s" : "b", count: abs(alteration))
        }
    }
}

/// An instrument the Score Wizard knows: its names, staff, clef, MIDI sound
/// and, for transposing instruments, how its written notes sound.
public struct Instrument: Hashable, Sendable, Identifiable {
    public enum Family: String, CaseIterable, Sendable {
        case woodwinds, brass, percussion, keyboards, pluckedStrings, voices, strings, other

        public var title: String {
            switch self {
            case .woodwinds: "Woodwinds"
            case .brass: "Brass"
            case .percussion: "Percussion"
            case .keyboards: "Keyboards"
            case .pluckedStrings: "Plucked Strings"
            case .voices: "Voices"
            case .strings: "Strings"
            case .other: "Other"
            }
        }
    }

    public enum Kind: Sendable {
        /// One staff.
        case single
        /// Two staves with a brace: piano, harp, celesta.
        case grand
        /// Two manual staves and a pedal staff.
        case organ
        /// A staff with lyrics.
        case voice
        /// A five-line drum staff.
        case drums
        /// A one-line staff for untuned percussion.
        case percussion
        /// A staff and tablature below it.
        case tablature
        /// Chord names above the music.
        case chordNames
    }

    /// Stable key, used in saved ensembles and by the Claude tool.
    public let id: String
    /// "Clarinet": the name without the key it's in, so players can be numbered
    /// ("Clarinet 1 in B♭").
    public let name: String
    /// "in B♭", after the name and number.
    public let pitchName: String?
    public let shortName: String
    public let family: Family
    public let kind: Kind
    /// Start of the music variable's name; players get I, II … added.
    public let variable: String
    /// Start of the file names; players get -1, -2 … added.
    public let file: String
    public let clef: String
    /// The pitch near the first notes, for `\relative` and `\fixed`.
    public let startPitch: Pitch
    public let midi: String
    /// Written c' sounds as this pitch (`\transposition`); nil when written
    /// as it sounds.
    public let transposition: Pitch?

    init(_ id: String, _ name: String, in pitchName: String? = nil, short: String, _ family: Family,
         kind: Kind = .single, variable: String? = nil, file: String? = nil, clef: String = "treble",
         start: String = "c''", midi: String, transposition: String? = nil) {
        self.id = id
        self.name = name
        self.pitchName = pitchName
        self.shortName = short
        self.family = family
        self.kind = kind
        self.variable = variable ?? id
        self.file = file ?? id
        self.clef = clef
        self.startPitch = Pitch(start)!
        self.midi = midi
        self.transposition = transposition.map { Pitch($0)! }
    }

    public static func == (a: Instrument, b: Instrument) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var title: String { [name, pitchName].compactMap { $0 }.joined(separator: " ") }
    /// For menus: tells the two guitars apart.
    public var menuTitle: String { kind == .tablature ? "\(title) with Tablature" : title }

    /// Transposes by octaves only (piccolo, double bass): written that way
    /// in every score, so always entered as written.
    public var transposesByOctave: Bool { transposition.map { $0.fifths == 0 && $0 != .middleC } ?? false }
    /// Written in another key than it sounds (clarinet, horn, saxophones).
    public var transposesKey: Bool { transposition.map { $0.fifths != 0 } ?? false }
    /// Has music of its own, so it gets a part.
    public var isPlayed: Bool { kind != .chordNames }
    var hasLyrics: Bool { kind == .voice }

    public static func named(_ id: String) -> Instrument? { byID[id] }
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// In score order within each family.
    public static let all: [Instrument] = [
        // Woodwinds
        Instrument("piccolo", "Piccolo", short: "Picc.", .woodwinds, start: "c'''", midi: "piccolo", transposition: "c''"),
        Instrument("flute", "Flute", short: "Fl.", .woodwinds, midi: "flute"),
        Instrument("alto-flute", "Alto Flute", in: "in G", short: "A. Fl.", .woodwinds, variable: "altoFlute",
                   midi: "flute", transposition: "g"),
        Instrument("oboe", "Oboe", short: "Ob.", .woodwinds, midi: "oboe"),
        Instrument("english-horn", "English Horn", short: "E. H.", .woodwinds, variable: "englishHorn",
                   midi: "english horn", transposition: "f"),
        Instrument("clarinet-e-flat", "Clarinet", in: "in E♭", short: "E♭ Cl.", .woodwinds, variable: "clarinetEFlat",
                   midi: "clarinet", transposition: "ees'"),
        Instrument("clarinet", "Clarinet", in: "in B♭", short: "Cl.", .woodwinds, midi: "clarinet", transposition: "bes"),
        Instrument("clarinet-a", "Clarinet", in: "in A", short: "Cl.", .woodwinds, variable: "clarinetA",
                   midi: "clarinet", transposition: "a"),
        Instrument("bass-clarinet", "Bass Clarinet", in: "in B♭", short: "B. Cl.", .woodwinds, variable: "bassClarinet",
                   start: "c'", midi: "clarinet", transposition: "bes,"),
        Instrument("soprano-sax", "Soprano Saxophone", short: "S. Sax.", .woodwinds, variable: "sopranoSax",
                   midi: "soprano sax", transposition: "bes"),
        Instrument("alto-sax", "Alto Saxophone", short: "A. Sax.", .woodwinds, variable: "altoSax",
                   midi: "alto sax", transposition: "ees"),
        Instrument("tenor-sax", "Tenor Saxophone", short: "T. Sax.", .woodwinds, variable: "tenorSax",
                   midi: "tenor sax", transposition: "bes,"),
        Instrument("baritone-sax", "Baritone Saxophone", short: "Bar. Sax.", .woodwinds, variable: "baritoneSax",
                   midi: "baritone sax", transposition: "ees,"),
        Instrument("bassoon", "Bassoon", short: "Bsn.", .woodwinds, clef: "bass", start: "c", midi: "bassoon"),
        Instrument("contrabassoon", "Contrabassoon", short: "Cbsn.", .woodwinds, clef: "bass", start: "c",
                   midi: "bassoon", transposition: "c"),
        Instrument("soprano-recorder", "Soprano Recorder", short: "S. Rec.", .woodwinds, variable: "sopranoRecorder",
                   midi: "recorder", transposition: "c''"),
        Instrument("alto-recorder", "Alto Recorder", short: "A. Rec.", .woodwinds, variable: "altoRecorder",
                   midi: "recorder"),
        Instrument("tenor-recorder", "Tenor Recorder", short: "T. Rec.", .woodwinds, variable: "tenorRecorder",
                   start: "c'", midi: "recorder"),

        // Brass
        Instrument("horn", "Horn", in: "in F", short: "Hn.", .brass, midi: "french horn", transposition: "f"),
        Instrument("trumpet", "Trumpet", in: "in B♭", short: "Tpt.", .brass, midi: "trumpet", transposition: "bes"),
        Instrument("trumpet-c", "Trumpet", in: "in C", short: "Tpt.", .brass, variable: "trumpetC", midi: "trumpet"),
        Instrument("cornet", "Cornet", in: "in B♭", short: "Cnt.", .brass, midi: "trumpet", transposition: "bes"),
        Instrument("flugelhorn", "Flugelhorn", short: "Flgh.", .brass, midi: "trumpet", transposition: "bes"),
        Instrument("trombone", "Trombone", short: "Tbn.", .brass, clef: "bass", start: "c", midi: "trombone"),
        Instrument("bass-trombone", "Bass Trombone", short: "B. Tbn.", .brass, variable: "bassTrombone",
                   clef: "bass", start: "c", midi: "trombone"),
        Instrument("euphonium", "Euphonium", short: "Euph.", .brass, clef: "bass", start: "c", midi: "trombone"),
        Instrument("tuba", "Tuba", short: "Tba.", .brass, clef: "bass", start: "c", midi: "tuba"),

        // Percussion
        Instrument("timpani", "Timpani", short: "Timp.", .percussion, clef: "bass", start: "c", midi: "timpani"),
        Instrument("glockenspiel", "Glockenspiel", short: "Glock.", .percussion, midi: "glockenspiel",
                   transposition: "c'''"),
        Instrument("xylophone", "Xylophone", short: "Xyl.", .percussion, midi: "xylophone", transposition: "c''"),
        Instrument("vibraphone", "Vibraphone", short: "Vib.", .percussion, start: "c'", midi: "vibraphone"),
        Instrument("marimba", "Marimba", short: "Mar.", .percussion, kind: .grand, midi: "marimba"),
        Instrument("tubular-bells", "Tubular Bells", short: "T. B.", .percussion, variable: "tubularBells",
                   midi: "tubular bells"),
        Instrument("drum-set", "Drum Set", short: "D. S.", .percussion, kind: .drums, variable: "drumSet",
                   clef: "percussion", midi: "drums"),
        Instrument("percussion", "Percussion", short: "Perc.", .percussion, kind: .percussion,
                   clef: "percussion", midi: "drums"),

        // Keyboards
        Instrument("piano", "Piano", short: "Pno.", .keyboards, kind: .grand, midi: "acoustic grand"),
        Instrument("harpsichord", "Harpsichord", short: "Hpsd.", .keyboards, kind: .grand, midi: "harpsichord"),
        Instrument("organ", "Organ", short: "Org.", .keyboards, kind: .organ, midi: "church organ"),
        Instrument("celesta", "Celesta", short: "Cel.", .keyboards, kind: .grand, midi: "celesta",
                   transposition: "c''"),

        // Plucked strings
        Instrument("harp", "Harp", short: "Hp.", .pluckedStrings, kind: .grand, midi: "orchestral harp"),
        Instrument("guitar", "Guitar", short: "Gtr.", .pluckedStrings, clef: "treble_8", start: "c'",
                   midi: "acoustic guitar (nylon)"),
        Instrument("guitar-tab", "Guitar", short: "Gtr.", .pluckedStrings, kind: .tablature, variable: "guitar",
                   file: "guitar", clef: "treble_8", start: "c'", midi: "acoustic guitar (nylon)"),
        Instrument("electric-guitar", "Electric Guitar", short: "E. Gtr.", .pluckedStrings,
                   variable: "electricGuitar", clef: "treble_8", start: "c'", midi: "electric guitar (clean)"),
        Instrument("bass-guitar", "Bass Guitar", short: "Bass", .pluckedStrings, variable: "bassGuitar",
                   clef: "bass", start: "c", midi: "electric bass (finger)", transposition: "c"),
        Instrument("mandolin", "Mandolin", short: "Mand.", .pluckedStrings, midi: "acoustic guitar (steel)"),
        Instrument("ukulele", "Ukulele", short: "Uk.", .pluckedStrings, start: "c'", midi: "acoustic guitar (nylon)"),

        // Voices
        Instrument("voice", "Voice", short: "V.", .voices, kind: .voice, variable: "melody", midi: "voice oohs"),
        Instrument("soprano", "Soprano", short: "S.", .voices, kind: .voice, midi: "choir aahs"),
        Instrument("mezzo-soprano", "Mezzo-soprano", short: "Mz.", .voices, kind: .voice, variable: "mezzo",
                   file: "mezzo", midi: "choir aahs"),
        Instrument("alto", "Alto", short: "A.", .voices, kind: .voice, start: "c'", midi: "choir aahs"),
        Instrument("tenor", "Tenor", short: "T.", .voices, kind: .voice, clef: "treble_8", start: "c'",
                   midi: "choir aahs"),
        Instrument("baritone", "Baritone", short: "Bar.", .voices, kind: .voice, clef: "bass", start: "c'",
                   midi: "choir aahs"),
        Instrument("bass", "Bass", short: "B.", .voices, kind: .voice, clef: "bass", start: "c", midi: "choir aahs"),

        // Strings
        Instrument("violin", "Violin", short: "Vln.", .strings, midi: "violin"),
        Instrument("viola", "Viola", short: "Vla.", .strings, clef: "alto", start: "c'", midi: "viola"),
        Instrument("cello", "Cello", short: "Vc.", .strings, clef: "bass", start: "c", midi: "cello"),
        Instrument("double-bass", "Double Bass", short: "Cb.", .strings, variable: "doubleBass", clef: "bass",
                   start: "c", midi: "contrabass", transposition: "c"),

        // Other
        Instrument("chord-names", "Chord Names", short: "", .other, kind: .chordNames, variable: "chordNames",
                   file: "chords", midi: ""),
    ]

    /// Players of the same instrument are numbered I, II … (strings, voices)
    /// or 1, 2 … (winds and the rest), as scores do.
    var usesRomanNumbers: Bool { family == .strings || family == .voices }
}
