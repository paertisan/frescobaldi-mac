import Foundation

/// An exact fraction, for LilyPond's moments and durations (in whole notes).
public struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    public private(set) var numerator: Int
    public private(set) var denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator != 0, "zero denominator")
        let sign = denominator < 0 ? -1 : 1
        let divisor = Swift.max(1, Rational.gcd(abs(numerator), abs(denominator)))
        self.numerator = sign * numerator / divisor
        self.denominator = sign * denominator / divisor
    }

    /// "3", "-1/4", as Scheme writes rationals.
    public init?<S: StringProtocol>(_ text: S) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard let n = Int(parts[0]) else { return nil }
        if parts.count == 1 { self.init(n); return }
        guard parts.count == 2, let d = Int(parts[1]), d != 0 else { return nil }
        self.init(n, d)
    }

    public static let zero = Rational(0)
    public static let one = Rational(1)

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }
    public var isZero: Bool { numerator == 0 }
    public var isNegative: Bool { numerator < 0 }
    public var doubleValue: Double { Double(numerator) / Double(denominator) }

    public static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    public static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }

    public static func + (a: Rational, b: Rational) -> Rational {
        let d = lcm(a.denominator, b.denominator)
        return Rational(a.numerator * (d / a.denominator) + b.numerator * (d / b.denominator), d)
    }
    public static func - (a: Rational, b: Rational) -> Rational { a + Rational(-b.numerator, b.denominator) }
    public static func * (a: Rational, b: Rational) -> Rational {
        let g1 = gcd(abs(a.numerator), b.denominator), g2 = gcd(abs(b.numerator), a.denominator)
        return Rational((a.numerator / Swift.max(g1, 1)) * (b.numerator / Swift.max(g2, 1)),
                        (a.denominator / Swift.max(g2, 1)) * (b.denominator / Swift.max(g1, 1)))
    }
    public static func / (a: Rational, b: Rational) -> Rational { a * Rational(b.denominator, b.numerator) }
    public static func < (a: Rational, b: Rational) -> Bool {
        a.numerator * b.denominator < b.numerator * a.denominator
    }
    public static func += (a: inout Rational, b: Rational) { a = a + b }
}

/// The music of a score as LilyPond interpreted it: what
/// Resources/LilyPond/fmac-export.ly writes, one record per line.
public struct ScoreEvents: Sendable {
    /// A point in time: whole notes from the start, and a grace offset
    /// (negative before the main note).
    public struct Moment: Hashable, Comparable, Sendable {
        public var main: Rational
        public var grace: Rational

        public init(_ main: Rational, grace: Rational = .zero) {
            self.main = main
            self.grace = grace
        }

        init?(_ text: Substring) {
            let parts = text.split(separator: ",")
            guard parts.count == 2, let main = Rational(parts[0]), let grace = Rational(parts[1]) else { return nil }
            self.init(main, grace: grace)
        }

        public static func < (a: Moment, b: Moment) -> Bool {
            a.main != b.main ? a.main < b.main : a.grace < b.grace
        }
    }

    /// LilyPond's pitch: octave 0 holds c', notename 0–6 is c–b, and the
    /// alteration is in whole tones (1/2 is a sharp).
    public struct Pitch: Hashable, Sendable {
        public var octave: Int
        public var notename: Int
        public var alteration: Rational

        public init(octave: Int, notename: Int, alteration: Rational = .zero) {
            self.octave = octave
            self.notename = notename
            self.alteration = alteration
        }

        init?(_ text: Substring) {
            let parts = text.split(separator: ",")
            guard parts.count == 3, let octave = Int(parts[0]), let notename = Int(parts[1]),
                  (0...6).contains(notename), let alteration = Rational(parts[2]) else { return nil }
            self.init(octave: octave, notename: notename, alteration: alteration)
        }

        /// Steps from c' (a seventh is 6).
        public var steps: Int { octave * 7 + notename }
        /// Semitones from c', rounded for quarter tones.
        public var semitones: Int {
            let scale = [0, 2, 4, 5, 7, 9, 11]
            return octave * 12 + scale[notename] + Int((alteration * Rational(2)).doubleValue.rounded())
        }
    }

    /// `log` 2 is a quarter, 0 a whole note, -1 a breve; `scale` is a
    /// tuplet's factor (2/3 for triplets) or a multiplier.
    public struct Duration: Hashable, Sendable {
        public var log: Int
        public var dots: Int
        public var scale: Rational

        public init(log: Int, dots: Int = 0, scale: Rational = .one) {
            self.log = log
            self.dots = dots
            self.scale = scale
        }

        init?(_ text: Substring) {
            let parts = text.split(separator: ",")
            guard parts.count == 3, let log = Int(parts[0]), let dots = Int(parts[1]),
                  let scale = Rational(parts[2]) else { return nil }
            self.init(log: log, dots: dots, scale: scale)
        }

        /// The value without the scale, in whole notes.
        public var unscaledLength: Rational {
            let base = log >= 0 ? Rational(1, 1 << Swift.min(log, 30)) : Rational(1 << Swift.min(-log, 30))
            // A dotted value is 2 - 1/2^dots times the plain one.
            return base * (Rational(2) - Rational(1, 1 << Swift.min(dots, 30)))
        }

        public var length: Rational { unscaledLength * scale }
    }

    /// A context above the staves: StaffGroup, PianoStaff, ChoirStaff ...
    public struct Context: Sendable {
        public var id: String
        public var name: String
        public var contextID: String
        public var parent: String?
        public var instrumentName: String
        public var shortInstrumentName: String
    }

    public struct Staff: Sendable {
        public var id: String
        public var name: String
        public var contextID: String
        public var parent: String?
    }

    /// A staff's settings from a moment on.
    public struct StaffProperties: Sendable, Equatable {
        public var moment: Moment
        public var clefGlyph: String
        public var clefPosition: Int
        public var clefTransposition: Int
        public var instrumentName: String
        public var shortInstrumentName: String
        public var midiInstrument: String
        /// General MIDI program, 0-based.
        public var midiProgram: Int?
        /// What a written c' sounds as (`\transposition`).
        public var transposition: Pitch?
        public var timeSignatureStyle: String
    }

    public struct Key: Sendable {
        public var staff: String
        public var moment: Moment
        public var tonic: Pitch
        /// Sharps (positive) or flats (negative).
        public var fifths: Int
    }

    /// The bar number, position in the bar and bar length from a moment on.
    public struct Bar: Sendable {
        public var moment: Moment
        public var number: Int
        public var position: Rational
        public var length: Rational
        public var timeSignature: (Int, Int)?
    }

    public struct Tempo: Sendable {
        public var moment: Moment
        public var text: String
        public var unit: Duration?
        public var count: Int?
    }

    public struct Mark: Sendable {
        public var moment: Moment
        public var label: String
        public var number: Int?
    }

    /// Something a voice heard: a note, rest, tie, slur, dynamic ...
    public struct Event: Sendable {
        public var voice: String
        public var staff: String
        public var moment: Moment
        public var kind: String
        public var duration: Duration?
        public var pitch: Pitch?
        /// -1 starts a spanner (slur, hairpin, tuplet), 1 ends it.
        public var spanDirection: Int?
        public var articulation: String?
        public var text: String?
        public var digit: Int?
        /// 1 above (^), -1 below (_).
        public var direction: Int?
        /// Part of the note before it (an articulation inside a chord).
        public var attached: Bool
    }

    public struct Lyric: Sendable {
        public var lyrics: String
        public var moment: Moment
        public var kind: String
        public var text: String
        public var voice: String?
    }

    public struct Score: Sendable {
        public var index: Int
        public var header: [String: String] = [:]
        public var contexts: [String: Context] = [:]
        public var staves: [Staff] = []
        public var properties: [String: [StaffProperties]] = [:]
        public var keys: [Key] = []
        public var bars: [Bar] = []
        public var barlines: [(moment: Moment, glyph: String)] = []
        public var tempos: [Tempo] = []
        public var marks: [Mark] = []
        public var events: [Event] = []
        public var lyrics: [Lyric] = []
        public var end: Moment = Moment(.zero)
        /// The bar line LilyPond adds at the end (finalBarType), if any.
        public var finalBar: String?
    }

    public var header: [String: String] = [:]
    public var scores: [Score] = []

    public init(header: [String: String] = [:], scores: [Score] = []) {
        self.header = header
        self.scores = scores
    }

    /// Reads fmac-export.ly's records; lines it doesn't know are skipped.
    public init(parsing text: String) {
        var current: Score?
        var scoreHeaders: [Int: [String: String]] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            func field(_ i: Int) -> Substring { i < f.count ? f[i] : "" }
            func string(_ i: Int) -> String { String(field(i)) }
            func int(_ i: Int) -> Int? { Int(field(i)) }
            func moment(_ i: Int) -> Moment? { Moment(field(i)) }
            func optional(_ i: Int) -> String? { field(i).isEmpty ? nil : string(i) }

            switch f[0] {
            case "header":
                header[string(1)] = string(2)
            case "scoreheader":
                if let index = int(1) { scoreHeaders[index, default: [:]][string(2)] = string(3) }
            case "score":
                if let current { scores.append(current) }
                current = Score(index: int(2) ?? scores.count + 1)
            case "ctx":
                current?.contexts[string(1)] = Context(id: string(1), name: string(2), contextID: string(3),
                                                       parent: optional(4), instrumentName: string(5),
                                                       shortInstrumentName: string(6))
            case "staff":
                current?.staves.append(Staff(id: string(1), name: string(2), contextID: string(3), parent: optional(4)))
            case "props":
                guard let m = moment(2) else { continue }
                let props = StaffProperties(
                    moment: m, clefGlyph: string(3), clefPosition: int(4) ?? 0, clefTransposition: int(5) ?? 0,
                    instrumentName: string(6), shortInstrumentName: string(7), midiInstrument: string(8),
                    midiProgram: int(9), transposition: Pitch(field(10)), timeSignatureStyle: string(11))
                current?.properties[string(1), default: []].append(props)
            case "key":
                guard let m = moment(2), let tonic = Pitch(field(3)) else { continue }
                current?.keys.append(Key(staff: string(1), moment: m, tonic: tonic, fifths: int(4) ?? 0))
            case "bar":
                guard let m = moment(1), let number = int(2),
                      let position = field(3).split(separator: ",").first.flatMap({ Rational($0) }),
                      let length = field(4).split(separator: ",").first.flatMap({ Rational($0) }) else { continue }
                let sig = field(5).split(separator: "/")
                let time = sig.count == 2 ? Int(sig[0]).flatMap { n in Int(sig[1]).map { (n, $0) } } : nil
                current?.bars.append(Bar(moment: m, number: number, position: position, length: length,
                                         timeSignature: time))
            case "barline":
                if let m = moment(1) { current?.barlines.append((m, string(2))) }
            case "tempo":
                if let m = moment(1) {
                    current?.tempos.append(Tempo(moment: m, text: string(2), unit: Duration(field(3)), count: int(4)))
                }
            case "mark":
                if let m = moment(1) { current?.marks.append(Mark(moment: m, label: string(2), number: int(3))) }
            case "ev":
                guard let m = moment(3) else { continue }
                current?.events.append(Event(
                    voice: string(1), staff: string(2), moment: m, kind: string(4),
                    duration: Duration(field(5)), pitch: Pitch(field(6)), spanDirection: int(7),
                    articulation: optional(8), text: optional(9), digit: int(10), direction: int(11),
                    attached: field(12) == "1"))
            case "lyric":
                guard let m = moment(2) else { continue }
                current?.lyrics.append(Lyric(lyrics: string(1), moment: m, kind: string(3), text: string(4),
                                             voice: optional(5)))
            case "end":
                if let m = moment(1) { current?.end = m }
                current?.finalBar = optional(2)
            default:
                continue
            }
        }
        if let current { scores.append(current) }
        for index in scores.indices {
            scores[index].header = scoreHeaders[scores[index].index] ?? [:]
        }
    }
}
