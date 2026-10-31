import Foundation

/// Everything the Score Wizard asks for. `ProjectTemplate.files(for:)` turns
/// it into a project.
public struct ScoreSpec: Equatable, Sendable {
    // Titles
    public var title = ""
    public var subtitle = ""
    public var composer = ""
    public var arranger = ""
    public var poet = ""
    public var opus = ""
    public var dedication = ""
    public var copyright = ""
    /// LilyPond's "Music engraving by LilyPond" line at the end.
    public var tagline = false

    // Ensemble
    public var players: [Player] = []
    public var grouping: Grouping = .byFamily

    // Music
    public var key = KeySignature()
    public var time = TimeSignature()
    /// Duration of the pickup (`\partial`), such as "4" or "8"; nil for none.
    public var pickup: String?
    public var tempo = Tempo()
    /// Empty bars to start with.
    public var bars = 4
    public var language: PitchLanguage = .nederlands
    public var entry: EntryMode = .relative
    /// Transposing instruments are entered as they sound; the score and
    /// parts transpose them. Otherwise they're entered as written.
    public var concertPitch = true
    /// The score shows transposing instruments as written; otherwise as they
    /// sound (a score in C). Only with `concertPitch`.
    public var transposedScore = true

    // Layout
    public var paperSize = "a4"
    public var landscape = false
    /// Nil: chosen from the number of staves.
    public var scoreStaffSize: Int?
    public var partStaffSize = 20
    public var makeParts = true
    public var instrumentNames: InstrumentNames = .fullThenShort
    /// Nil: on for eight staves or more.
    public var hideEmptyStaves: Bool?
    public var midi = true

    public init() {}

    public init(ensemble: Ensemble) {
        apply(ensemble)
    }

    /// Takes the players and the ensemble's usual settings.
    public mutating func apply(_ ensemble: Ensemble) {
        players = ensemble.instruments.map { Player(instrument: $0) }
        grouping = ensemble.grouping
        instrumentNames = ensemble.instrumentNames
        makeParts = ensemble.makeParts
        hideEmptyStaves = nil
        scoreStaffSize = nil
    }

    // MARK: Derived

    public var resolvedPlayers: [ResolvedPlayer] { ResolvedPlayer.resolve(players) }

    /// Staves in the score, counting a piano as two.
    public var staffCount: Int {
        resolvedPlayers.reduce(0) { count, player in
            switch player.instrument.kind {
            case .grand, .tablature: count + 2
            case .organ: count + 3
            case .chordNames: count
            default: count + 1
            }
        }
    }

    public var effectiveScoreStaffSize: Int {
        if let scoreStaffSize { return scoreStaffSize }
        switch staffCount {
        case ...3: return 20
        case ...6: return 18
        case ...14: return 16
        case ...22: return 14
        default: return 12
        }
    }

    public var effectiveHideEmptyStaves: Bool { hideEmptyStaves ?? (staffCount >= 8) }

    /// Where a new player of `instrument` goes: after the others of its
    /// family, or else in score order; chord names on top.
    public func insertionIndex(for instrument: Instrument) -> Int {
        if instrument.kind == .chordNames { return 0 }
        let families = players.map { Instrument.named($0.instrument)?.family ?? .other }
        if let last = families.lastIndex(of: instrument.family) { return last + 1 }
        let order = Instrument.Family.allCases
        let rank = order.firstIndex(of: instrument.family) ?? 0
        return families.firstIndex { $0 != .other && order.firstIndex(of: $0)! > rank } ?? players.count
    }

    /// Players with music of their own (not chord names).
    public var playedCount: Int { resolvedPlayers.filter(\.instrument.isPlayed).count }
    public var hasParts: Bool { makeParts && playedCount > 1 }
    public var hasKeyTransposingInstruments: Bool { resolvedPlayers.contains { $0.instrument.transposesKey } }
}

/// One staff (or piano, or voice with lyrics) in the score.
public struct Player: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// An `Instrument.id`.
    public var instrument: String
    /// A name of the user's instead of the numbered one, such as "Solo Violin".
    public var name: String?

    public init(instrument: String, name: String? = nil) {
        self.instrument = instrument
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case instrument, name }
}

/// A player with its instrument, names and the names of its variable and file.
public struct ResolvedPlayer: Hashable, Sendable {
    public let instrument: Instrument
    /// 1, 2 … when several players play the same instrument.
    public let number: Int?
    public let name: String
    /// The name without the user's: "Violin II".
    public let numberedName: String
    public let shortName: String
    /// The music variable: `clarinetI`.
    public let variable: String
    /// The file name without extension: `clarinet-1`.
    public let file: String

    static func resolve(_ players: [Player]) -> [ResolvedPlayer] {
        let known = players.compactMap { player in Instrument.named(player.instrument).map { (player, $0) } }
        // Numbered by variable, so two kinds of guitar don't share one.
        var totals: [String: Int] = [:]
        for (_, instrument) in known { totals[instrument.variable, default: 0] += 1 }
        var counts: [String: Int] = [:]
        return known.map { player, instrument in
            var number: Int?
            if totals[instrument.variable, default: 0] > 1 {
                counts[instrument.variable, default: 0] += 1
                number = counts[instrument.variable]
            }
            let label = number.map { instrument.usesRomanNumbers ? roman($0) : String($0) }
            let numbered = [instrument.name, label, instrument.pitchName].compactMap { $0 }.joined(separator: " ")
            let custom = player.name?.trimmingCharacters(in: .whitespaces)
            return ResolvedPlayer(
                instrument: instrument, number: number,
                name: custom.flatMap { $0.isEmpty ? nil : $0 } ?? numbered, numberedName: numbered,
                shortName: [instrument.shortName, label].compactMap { $0 }.joined(separator: " "),
                variable: instrument.variable + (number.map(roman) ?? ""),
                file: instrument.file + (number.map { "-\($0)" } ?? ""))
        }
    }

    static func roman(_ number: Int) -> String {
        let values = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var number = number
        var result = ""
        for (value, letters) in values {
            while number >= value { result += letters; number -= value }
        }
        return result
    }
}

public enum Grouping: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A bracket around each family (woodwinds, brass …), a choir bracket for voices.
    case byFamily
    /// One bracket around everything.
    case together
    case none
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .byFamily: "By family"
        case .together: "All together"
        case .none: "None"
        }
    }
}

public enum InstrumentNames: String, CaseIterable, Sendable, Identifiable {
    case fullThenShort, full, none
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullThenShort: "Full, then short"
        case .full: "On the first system"
        case .none: "None"
        }
    }
}

public enum EntryMode: String, CaseIterable, Sendable, Identifiable {
    case relative, fixed, absolute
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .relative: "Relative (\\relative)"
        case .fixed: "Fixed octave (\\fixed)"
        case .absolute: "Absolute"
        }
    }
}

public struct KeySignature: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case major, minor, dorian, phrygian, lydian, mixolydian, locrian
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        /// Sharps (+) or flats (-) of the mode on c.
        var offset: Int {
            switch self {
            case .major: 0
            case .minor: -3
            case .dorian: -2
            case .phrygian: -4
            case .lydian: 1
            case .mixolydian: -1
            case .locrian: -5
            }
        }
    }

    public var tonic: Pitch
    public var mode: Mode

    public init(tonic: Pitch = Pitch(0), mode: Mode = .major) {
        self.tonic = tonic
        self.mode = mode
    }

    /// Sharps (+) or flats (-) in the signature.
    public var fifths: Int { tonic.fifths + mode.offset }

    /// The keys with up to seven sharps or flats, flats first.
    public static func keys(_ mode: Mode) -> [KeySignature] {
        (-7...7).map { KeySignature(tonic: Pitch.at(fifths: $0 - mode.offset, near: Pitch(0)), mode: mode) }
    }

    /// "E♭ major".
    public var title: String { "\(tonic.displayName) \(mode.rawValue)" }
}

public struct TimeSignature: Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int
    /// C and ¢ for 4/4 and 2/2, as LilyPond prints them by default.
    public var symbol: Bool

    public init(_ numerator: Int = 4, _ denominator: Int = 4, symbol: Bool = true) {
        self.numerator = numerator
        self.denominator = denominator
        self.symbol = symbol
    }

    public var hasSymbol: Bool { (numerator, denominator) == (4, 4) || (numerator, denominator) == (2, 2) }

    public var title: String {
        guard hasSymbol && symbol else { return "\(numerator)/\(denominator)" }
        return numerator == 4 ? "C (4/4)" : "¢ (2/2)"
    }

    public static let common: [TimeSignature] = [
        TimeSignature(4, 4), TimeSignature(4, 4, symbol: false), TimeSignature(2, 2), TimeSignature(2, 2, symbol: false),
        TimeSignature(2, 4), TimeSignature(3, 4), TimeSignature(5, 4), TimeSignature(6, 4),
        TimeSignature(3, 8), TimeSignature(6, 8), TimeSignature(9, 8), TimeSignature(12, 8), TimeSignature(7, 8),
        TimeSignature(3, 2),
    ]

    public var isValid: Bool { numerator > 0 && numerator <= 32 && [1, 2, 4, 8, 16, 32, 64].contains(denominator) }

    /// A full bar as a LilyPond duration, for rests and skips: "1", "2.", "8*7".
    public var barDuration: String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(numerator, denominator)
        let (n, d) = (numerator / divisor, denominator / divisor)
        let plain = [1, 2, 4, 8, 16, 32, 64]
        if n == 1, plain.contains(d) { return "\(d)" }
        if n == 2, d == 1 { return "\\breve" }
        if n == 3, d % 2 == 0, plain.contains(d / 2) { return "\(d / 2)." }
        return "\(denominator)*\(numerator)"
    }

    /// Pickup durations, shortest first.
    public static let pickups = ["16", "8", "8.", "4", "4.", "2", "2."]

    /// Whether a pickup of `duration` is shorter than a bar.
    public func fits(pickup duration: String) -> Bool {
        guard let base = Int(duration.filter(\.isNumber)), base > 0 else { return false }
        // duration = 1/base, or 3/(2 base) dotted; compare with numerator/denominator.
        let (n, d) = duration.hasSuffix(".") ? (3, 2 * base) : (1, base)
        return n * denominator < numerator * d
    }

    /// The usual beat for a metronome mark.
    public var beat: String {
        switch denominator {
        case 8 where numerator % 3 == 0: "4."
        case 16 where numerator % 3 == 0: "8."
        default: "\(denominator)"
        }
    }
}

public struct Tempo: Hashable, Sendable {
    /// "Allegro"; empty for none.
    public var text: String
    /// The beat of the metronome mark ("4", "4."); nil for none.
    public var beat: String?
    public var bpm: Int

    public init(text: String = "", beat: String? = nil, bpm: Int = 100) {
        self.text = text
        self.beat = beat
        self.bpm = bpm
    }
}

/// A preset ensemble.
public struct Ensemble: Hashable, Sendable, Identifiable {
    public enum Category: String, CaseIterable, Sendable {
        case solo, chamber, choir, orchestra, popular
        public var title: String {
            switch self {
            case .solo: "Solo and Duo"
            case .chamber: "Chamber Music"
            case .choir: "Choir"
            case .orchestra: "Orchestra and Band"
            case .popular: "Songs and Bands"
            }
        }
    }

    public let id: String
    public let title: String
    public let category: Category
    public let instruments: [String]
    public let grouping: Grouping
    public let instrumentNames: InstrumentNames
    public let makeParts: Bool

    init(_ id: String, _ title: String, _ category: Category, _ instruments: [String],
         grouping: Grouping = .byFamily, names: InstrumentNames = .fullThenShort, parts: Bool = true) {
        self.id = id
        self.title = title
        self.category = category
        self.instruments = instruments
        self.grouping = grouping
        self.instrumentNames = names
        self.makeParts = parts
    }

    public static func named(_ id: String) -> Ensemble? { all.first { $0.id == id } }

    public static let all: [Ensemble] = [
        Ensemble("piano", "Piano", .solo, ["piano"], names: .none),
        Ensemble("organ", "Organ", .solo, ["organ"], names: .none),
        Ensemble("guitar", "Guitar", .solo, ["guitar"], names: .none),
        Ensemble("guitar-tab", "Guitar with Tablature", .solo, ["guitar-tab"], names: .none),
        Ensemble("voice-piano", "Voice and Piano", .solo, ["voice", "piano"], grouping: .none, names: .none),
        Ensemble("violin-piano", "Violin and Piano", .solo, ["violin", "piano"], grouping: .none, names: .full),
        Ensemble("cello-piano", "Cello and Piano", .solo, ["cello", "piano"], grouping: .none, names: .full),
        Ensemble("flute-piano", "Flute and Piano", .solo, ["flute", "piano"], grouping: .none, names: .full),
        Ensemble("clarinet-piano", "Clarinet and Piano", .solo, ["clarinet", "piano"], grouping: .none, names: .full),

        Ensemble("string-quartet", "String Quartet", .chamber, ["violin", "violin", "viola", "cello"]),
        Ensemble("piano-trio", "Piano Trio", .chamber, ["violin", "cello", "piano"], grouping: .none),
        Ensemble("wind-quintet", "Wind Quintet", .chamber, ["flute", "oboe", "clarinet", "horn", "bassoon"],
                 grouping: .together),
        Ensemble("brass-quintet", "Brass Quintet", .chamber, ["trumpet", "trumpet", "horn", "trombone", "tuba"]),
        Ensemble("saxophone-quartet", "Saxophone Quartet", .chamber,
                 ["soprano-sax", "alto-sax", "tenor-sax", "baritone-sax"]),

        Ensemble("satb", "SATB Choir", .choir, ["soprano", "alto", "tenor", "bass"], parts: false),
        Ensemble("satb-piano", "SATB Choir and Piano", .choir, ["soprano", "alto", "tenor", "bass", "piano"],
                 parts: false),
        Ensemble("satb-organ", "SATB Choir and Organ", .choir, ["soprano", "alto", "tenor", "bass", "organ"],
                 parts: false),

        Ensemble("string-orchestra", "String Orchestra", .orchestra,
                 ["violin", "violin", "viola", "cello", "double-bass"]),
        Ensemble("chamber-orchestra", "Chamber Orchestra", .orchestra,
                 ["flute", "oboe", "clarinet", "bassoon", "horn", "trumpet", "timpani",
                  "violin", "violin", "viola", "cello", "double-bass"]),
        Ensemble("orchestra", "Symphony Orchestra", .orchestra,
                 ["piccolo", "flute", "oboe", "clarinet", "bassoon", "horn", "horn", "trumpet", "trombone", "tuba",
                  "timpani", "harp", "violin", "violin", "viola", "cello", "double-bass"]),
        Ensemble("concert-band", "Concert Band", .orchestra,
                 ["flute", "oboe", "bassoon", "clarinet", "clarinet", "clarinet", "bass-clarinet",
                  "alto-sax", "alto-sax", "tenor-sax", "baritone-sax",
                  "trumpet", "trumpet", "trumpet", "horn", "trombone", "trombone", "euphonium", "tuba",
                  "timpani", "percussion"]),

        Ensemble("lead-sheet", "Lead Sheet", .popular, ["chord-names", "voice"], names: .none, parts: false),
        Ensemble("rock-band", "Rock Band", .popular,
                 ["voice", "electric-guitar", "bass-guitar", "piano", "drum-set"], grouping: .none),
        Ensemble("jazz-combo", "Jazz Combo", .popular,
                 ["trumpet", "tenor-sax", "piano", "double-bass", "drum-set"], grouping: .none),
    ]
}

extension Pitch {
    /// "E♭", "F♯": for menus.
    public var displayName: String {
        ["C", "D", "E", "F", "G", "A", "B"][step]
            + String(repeating: alteration > 0 ? "♯" : "♭", count: abs(alteration))
    }
}
