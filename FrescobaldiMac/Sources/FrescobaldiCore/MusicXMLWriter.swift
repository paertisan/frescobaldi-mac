import Foundation

/// Writes MusicXML 4.0 (partwise) from the music LilyPond interpreted
/// (`ScoreEvents`), one document per score.
///
/// Every staff is a part, except that the staves of a PianoStaff (piano,
/// harp, the hands of an organ) make one part. StaffGroup, ChoirStaff and
/// GrandStaff (two flutes, divisi strings) become part groups. Measures follow LilyPond's bar numbers
/// and lengths; notes that cross a bar line are split and tied.
/// Beams are written as LilyPond draws them; accidentals and stems are
/// left to the program that reads the file (it's told so with `<supports>`).
public struct MusicXMLWriter: Sendable {
    public var software: String
    /// The encoding date, YYYY-MM-DD.
    public var date: String

    public init(software: String = "Frescobaldi for macOS", date: Date = Date()) {
        self.software = software
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        self.date = formatter.string(from: date)
    }

    /// One MusicXML document per score in the events.
    public func documents(_ events: ScoreEvents) -> [String] {
        events.scores.map { document($0, header: events.header) }
    }

    public func document(_ score: ScoreEvents.Score, header: [String: String]) -> String {
        ScoreBuilder(score: score, header: header, writer: self).build()
    }

    /// Plain note values (log, dots) that add up to `length` in whole notes.
    static func noteValues(_ length: Rational) -> [(log: Int, dots: Int)]? { Renderer.noteValues(length) }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

// MARK: - XML text

struct XMLText {
    private(set) var text = ""
    private var depth = 0

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    private static func attributes(_ attrs: KeyValuePairs<String, String>) -> String {
        attrs.map { " \($0.key)=\"\(escape($0.value))\"" }.joined()
    }

    mutating func line(_ s: String) {
        text += String(repeating: "  ", count: depth) + s + "\n"
    }

    mutating func open(_ tag: String, _ attrs: KeyValuePairs<String, String> = [:]) {
        line("<\(tag)\(Self.attributes(attrs))>")
        depth += 1
    }

    mutating func close(_ tag: String) {
        depth -= 1
        line("</\(tag)>")
    }

    mutating func leaf(_ tag: String, _ value: String, _ attrs: KeyValuePairs<String, String> = [:]) {
        line("<\(tag)\(Self.attributes(attrs))>\(Self.escape(value))</\(tag)>")
    }

    mutating func empty(_ tag: String, _ attrs: KeyValuePairs<String, String> = [:]) {
        line("<\(tag)\(Self.attributes(attrs))/>")
    }

    mutating func append(_ other: XMLText) {
        for line in other.text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            self.line(String(line))
        }
    }
}

// MARK: - Building one score

private struct ScoreBuilder {
    typealias Moment = ScoreEvents.Moment
    typealias Event = ScoreEvents.Event

    let score: ScoreEvents.Score
    let header: [String: String]
    let writer: MusicXMLWriter

    struct Measure {
        var start: Rational
        var length: Rational
        var number: Int
        var implicit: Bool
        var time: (Int, Int)?
        var end: Rational { start + length }
    }

    struct Note {
        var pitch: ScoreEvents.Pitch
        var tieStart = false
        var tieStop = false
        var events: [Event] = []
    }

    enum ChordKind { case notes, rest, measureRest }

    /// Notes (or a rest) that start together in one voice.
    struct Chord {
        var moment: Moment
        var voice: String
        var staff: String
        var kind: ChordKind
        var duration: ScoreEvents.Duration
        var notes: [Note] = []
        var events: [Event] = []
        var hidden = false
        /// <beam> values by level (1: eighths), when the chord is beamed.
        var beams: [String] = []
        /// Events that end at this chord though they arrived later (tuplet ends).
        var endEvents: [Event] = []
        var lyrics: [(number: Int, syllabic: String, text: String, extend: Bool)] = []
        var isGrace: Bool { moment.grace.isNegative }
        var length: Rational { isGrace ? .zero : duration.length }
    }

    /// A dynamic or text with no note of its own, such as `s2\<`.
    struct LooseDirection {
        var moment: Moment
        var voice: String
        var staff: String
        var events: [Event]
    }

    struct Part {
        var id: String
        var staves: [String]
        var name: String
        var abbreviation: String
        var groups: [String] = []
    }

    struct Repeats {
        var forward: Set<Rational> = []
        var backward: [Rational: Int] = [:]
        var endingStart: [Rational: String] = [:]
        var endingStop: [Rational: String] = [:]
    }

    // MARK: Build

    func build() -> String {
        let measures = buildMeasures()
        let parts = buildParts()
        let (chords, loose) = buildChords()
        let repeats = buildRepeats()

        var renderer = Renderer(builder: self, measures: measures, parts: parts, chords: chords,
                                loose: loose, repeats: repeats)
        return renderer.render()
    }

    func buildMeasures() -> [Measure] {
        let end = score.end.main
        guard end > .zero else { return [] }
        struct Anchor { var start: Rational; var number: Int; var length: Rational; var time: (Int, Int)?; var implicit: Bool }
        var anchors: [Anchor] = []
        func add(_ anchor: Anchor) {
            if let last = anchors.last, last.start == anchor.start {
                anchors[anchors.count - 1] = anchor
            } else if anchors.last.map({ $0.start < anchor.start }) ?? true {
                anchors.append(anchor)
            }
        }
        for bar in score.bars where bar.length > .zero {
            let at = bar.moment.main
            if bar.position.isNegative {
                // \partial: a short bar until the first bar line.
                add(Anchor(start: at, number: bar.number - 1, length: Rational.zero - bar.position,
                           time: bar.timeSignature, implicit: true))
                add(Anchor(start: at - bar.position, number: bar.number, length: bar.length,
                           time: bar.timeSignature, implicit: false))
            } else {
                add(Anchor(start: at - bar.position, number: bar.number, length: bar.length,
                           time: bar.timeSignature, implicit: false))
            }
        }
        if anchors.isEmpty { anchors = [Anchor(start: .zero, number: 1, length: end, time: nil, implicit: false)] }

        var measures: [Measure] = []
        for (index, anchor) in anchors.enumerated() {
            let limit = index + 1 < anchors.count ? anchors[index + 1].start : end
            var start = anchor.start
            var number = anchor.number
            while start < limit {
                let length = Swift.min(anchor.length, limit - start)
                guard length > .zero else { break }
                measures.append(Measure(start: start, length: length, number: number,
                                        implicit: anchor.implicit, time: anchor.time))
                start += length
                number += 1
                if anchor.implicit { break }
            }
        }
        return measures
    }

    /// The context that makes one part of its staves.
    func mergingContext(of staff: ScoreEvents.Staff) -> String? {
        var id = staff.parent
        while let current = id, let context = score.contexts[current] {
            if context.name == "PianoStaff" { return current }
            id = context.parent
        }
        return nil
    }

    static let groupNames: Set<String> = ["StaffGroup", "ChoirStaff", "GrandStaff", "PianoStaff",
                                          "InnerStaffGroup", "InnerChoirStaff"]

    func buildParts() -> [Part] {
        var parts: [Part] = []
        var partForKey: [String: Int] = [:]
        for staff in score.staves {
            let merge = mergingContext(of: staff)
            let key = merge ?? staff.id
            if let index = partForKey[key] {
                parts[index].staves.append(staff.id)
                continue
            }
            // The name at the start, or one set later (\set Staff.instrumentName
            // for the next systems), or the MIDI instrument's.
            let timeline = score.properties[staff.id] ?? []
            let shorts = timeline.compactMap { $0.shortInstrumentName.nonEmpty }
            let names = timeline.compactMap { $0.instrumentName.nonEmpty }
            let instrument = timeline.first?.midiInstrument ?? ""
            let fromMIDI = instrument.prefix(1).uppercased() + instrument.dropFirst()
            var short: String = shorts.first ?? ""
            var name: String = names.first ?? shorts.first ?? fromMIDI.nonEmpty ?? staff.contextID
            if let merge, let context = score.contexts[merge] {
                if !context.instrumentName.isEmpty { name = context.instrumentName }
                if !context.shortInstrumentName.isEmpty { short = context.shortInstrumentName }
            }
            // Groups above the part, outermost first.
            var groups: [String] = []
            var id = merge.flatMap { score.contexts[$0]?.parent } ?? staff.parent
            while let current = id, let context = score.contexts[current] {
                if Self.groupNames.contains(context.name) { groups.insert(current, at: 0) }
                id = context.parent
            }
            partForKey[key] = parts.count
            parts.append(Part(id: "P\(parts.count + 1)", staves: [staff.id], name: name, abbreviation: short,
                              groups: groups))
        }
        return parts
    }

    static let scoreLevelKinds: Set<String> = ["volta-repeat-start-event", "volta-repeat-end-event",
                                               "volta-span-event", "alternative-event", "bar-event"]
    static let rhythmicKinds: Set<String> = ["note-event", "rest-event", "multi-measure-rest-event"]
    /// Events that belong to the note before them when they arrive with no note.
    static let endingKinds: Set<String> = ["tie-event", "breathing-event"]

    func buildChords() -> ([Chord], [LooseDirection]) {
        var chords: [Chord] = []
        var loose: [LooseDirection] = []
        var lastChordOfVoice: [String: Int] = [:]

        // Events arrive in time order; group each voice's events by moment.
        var groups: [(voice: String, moment: Moment, events: [Event])] = []
        var groupIndex: [String: Int] = [:]
        for event in score.events where !Self.scoreLevelKinds.contains(event.kind) {
            if let index = groupIndex[event.voice], groups[index].moment == event.moment {
                groups[index].events.append(event)
            } else {
                groupIndex[event.voice] = groups.count
                groups.append((event.voice, event.moment, [event]))
            }
        }

        closeHairpins(&groups)
        for group in groups {
            let rhythmic = group.events.filter { !$0.attached && Self.rhythmicKinds.contains($0.kind) }
            let previous = lastChordOfVoice[group.voice]
            guard let first = rhythmic.first, let duration = first.duration else {
                // No note here: ends go to the voice's last note, the rest stands alone.
                var directions: [Event] = []
                for event in group.events {
                    if let previous, endsPreviousChord(event) {
                        chords[previous].endEvents.append(event)
                    } else if event.kind == "tie-event", let previous {
                        for n in chords[previous].notes.indices { chords[previous].notes[n].tieStart = true }
                    } else {
                        directions.append(event)
                    }
                }
                if !directions.isEmpty {
                    loose.append(LooseDirection(moment: group.moment, voice: group.voice,
                                                staff: group.events[0].staff, events: directions))
                }
                continue
            }
            let kind: ChordKind = first.kind == "note-event" ? .notes
                : first.kind == "rest-event" ? .rest : .measureRest
            var chord = Chord(moment: group.moment, voice: group.voice, staff: first.staff, kind: kind,
                              duration: duration)
            chord.hidden = rhythmic.allSatisfy(\.hidden)
            var tieAll = false
            for event in group.events {
                if event.attached {
                    if !chord.notes.isEmpty {
                        if event.kind == "tie-event" {
                            chord.notes[chord.notes.count - 1].tieStart = true
                        } else {
                            chord.notes[chord.notes.count - 1].events.append(event)
                        }
                    } else {
                        chord.events.append(event)
                    }
                } else if event.kind == "note-event", let pitch = event.pitch {
                    chord.notes.append(Note(pitch: pitch))
                } else if Self.rhythmicKinds.contains(event.kind) {
                    continue
                } else if event.kind == "tie-event" {
                    tieAll = true
                } else if let previous, endsPreviousChord(event) {
                    chords[previous].endEvents.append(event)
                } else {
                    chord.events.append(event)
                }
            }
            if tieAll { for n in chord.notes.indices { chord.notes[n].tieStart = true } }
            if kind == .notes && chord.notes.isEmpty { chord.kind = .rest }
            lastChordOfVoice[group.voice] = chords.count
            chords.append(chord)
        }

        // Tie ends: the next chord in the voice with the same pitch.
        var byVoice: [String: [Int]] = [:]
        for (index, chord) in chords.enumerated() { byVoice[chord.voice, default: []].append(index) }
        for indices in byVoice.values {
            for (i, index) in indices.enumerated() where i + 1 < indices.count {
                let next = indices[i + 1]
                for note in chords[index].notes where note.tieStart {
                    if let n = chords[next].notes.firstIndex(where: { $0.pitch == note.pitch }) {
                        chords[next].notes[n].tieStop = true
                    }
                }
            }
        }
        attachLyrics(&chords, byVoice: byVoice)
        attachBeams(&chords, byVoice: byVoice)
        return (chords, loose)
    }

    /// A hairpin ends at the next dynamic or hairpin when no \! ends it.
    func closeHairpins(_ groups: inout [(voice: String, moment: Moment, events: [Event])]) {
        var open: Set<String> = []
        for g in groups.indices {
            var events: [Event] = []
            for event in groups[g].events {
                let voice = groups[g].voice
                let hairpin = event.kind == "crescendo-event" || event.kind == "decrescendo-event"
                if hairpin && event.spanDirection == 1 {
                    if !open.contains(voice) { continue }
                    open.remove(voice)
                } else if (hairpin && event.spanDirection == -1) || event.kind == "absolute-dynamic-event" {
                    if open.contains(voice) {
                        var stop = event
                        stop.kind = "crescendo-event"
                        stop.spanDirection = 1
                        stop.attached = false
                        events.append(stop)
                        open.remove(voice)
                    }
                    if hairpin { open.insert(voice) }
                }
                events.append(event)
            }
            groups[g].events = events
        }
    }

    /// MusicXML's beam values for each beamed chord: begin, continue and
    /// end on every level its notes share, hooks where one note has more.
    func attachBeams(_ chords: inout [Chord], byVoice: [String: [Int]]) {
        var chordAt: [String: [Moment: Int]] = [:]
        for (voice, indices) in byVoice {
            for index in indices where chords[index].kind != .measureRest {
                chordAt[voice, default: [:]][chords[index].moment] = index
            }
        }
        for beam in score.beams {
            let members = beam.moments.compactMap { chordAt[beam.voice]?[$0] }
            guard members.count > 1 else { continue }
            let levels = members.map { Swift.max(0, chords[$0].duration.log - 2) }
            guard let top = levels.max(), top > 0 else { continue }
            for level in 1...top {
                for (i, index) in members.enumerated() where levels[i] >= level {
                    let before = i > 0 && levels[i - 1] >= level
                    let after = i + 1 < members.count && levels[i + 1] >= level
                    let value: String
                    switch (before, after) {
                    case (false, true): value = "begin"
                    case (true, true): value = "continue"
                    case (true, false): value = "end"
                    case (false, false): value = i + 1 < members.count ? "forward hook" : "backward hook"
                    }
                    if chords[index].beams.count == level - 1 { chords[index].beams.append(value) }
                }
            }
        }
    }

    func endsPreviousChord(_ event: Event) -> Bool {
        if event.kind == "breathing-event" { return true }
        return event.kind == "tuplet-span-event" && event.spanDirection == 1
    }

    func attachLyrics(_ chords: inout [Chord], byVoice: [String: [Int]]) {
        var numberOf: [String: Int] = [:]
        var countForVoice: [String: Int] = [:]
        var hyphenBefore: [String: Bool] = [:]
        // Group each Lyrics context's records by moment.
        var groups: [(lyrics: String, moment: Moment, voice: String?, text: String?, hyphen: Bool, extend: Bool)] = []
        var groupIndex: [String: Int] = [:]
        for lyric in score.lyrics {
            if let index = groupIndex[lyric.lyrics], groups[index].moment == lyric.moment {
                if lyric.kind == "hyphen-event" { groups[index].hyphen = true }
                if lyric.kind == "extender-event" { groups[index].extend = true }
                if lyric.kind == "lyric-event" { groups[index].text = lyric.text }
            } else {
                groupIndex[lyric.lyrics] = groups.count
                groups.append((lyric.lyrics, lyric.moment, lyric.voice,
                               lyric.kind == "lyric-event" ? lyric.text : nil,
                               lyric.kind == "hyphen-event", lyric.kind == "extender-event"))
            }
        }
        var chordAt: [String: [Moment: Int]] = [:]
        for (voice, indices) in byVoice {
            for index in indices where chords[index].kind == .notes && chordAt[voice]?[chords[index].moment] == nil {
                chordAt[voice, default: [:]][chords[index].moment] = index
            }
        }
        for group in groups {
            guard let voice = group.voice, let text = group.text,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty, text != "_" else { continue }
            let number: Int
            if let known = numberOf[group.lyrics] {
                number = known
            } else {
                number = (countForVoice[voice] ?? 0) + 1
                countForVoice[voice] = number
                numberOf[group.lyrics] = number
            }
            let before = hyphenBefore[group.lyrics] ?? false
            hyphenBefore[group.lyrics] = group.hyphen
            let syllabic = before ? (group.hyphen ? "middle" : "end") : (group.hyphen ? "begin" : "single")
            guard let index = chordAt[voice]?[group.moment] else { continue }
            chords[index].lyrics.append((number, syllabic, text, group.extend))
        }
    }

    func buildRepeats() -> Repeats {
        var repeats = Repeats()
        for event in score.events where Self.scoreLevelKinds.contains(event.kind) {
            let at = event.moment.main
            switch event.kind {
            case "volta-repeat-start-event":
                repeats.forward.insert(at)
            case "volta-repeat-end-event":
                repeats.backward[at] = event.digit ?? repeats.backward[at] ?? 2
            case "volta-span-event":
                let numbers = (event.text ?? "").split(separator: " ").joined(separator: ", ")
                if event.spanDirection == -1 { repeats.endingStart[at] = numbers }
                if event.spanDirection == 1 { repeats.endingStop[at] = numbers }
            default:
                break
            }
        }
        // A bar line typed with \bar ".|:" and the like.
        for (moment, glyph) in score.barlines {
            let at = moment.main
            if glyph.hasSuffix(":") && !repeats.forward.contains(at) { repeats.forward.insert(at) }
            if glyph.hasPrefix(":") && repeats.backward[at] == nil { repeats.backward[at] = 2 }
        }
        return repeats
    }
}

// MARK: - Rendering

private struct Renderer {
    typealias Moment = ScoreEvents.Moment
    typealias Event = ScoreEvents.Event
    typealias Measure = ScoreBuilder.Measure
    typealias Chord = ScoreBuilder.Chord

    let builder: ScoreBuilder
    let measures: [Measure]
    let parts: [ScoreBuilder.Part]
    let chords: [Chord]
    let loose: [ScoreBuilder.LooseDirection]
    let repeats: ScoreBuilder.Repeats
    var score: ScoreEvents.Score { builder.score }

    /// A piece of a chord inside one measure.
    struct Piece {
        var chord: Int
        var measure: Int
        var onset: Rational
        var length: Rational
        var values: [(log: Int, dots: Int)]
        var first: Bool
        var last: Bool
    }

    var pieces: [Piece] = []
    var divisions = 1
    /// Pieces, and chords and loose directions by where they start, per measure.
    var piecesInMeasure: [Int: [Int]] = [:]
    var chordsStartingIn: [Int: [Int]] = [:]
    var looseStartingIn: [Int: [Int]] = [:]
    var voicesOfPart: [String: [String: Int]] = [:]

    init(builder: ScoreBuilder, measures: [Measure], parts: [ScoreBuilder.Part], chords: [Chord],
         loose: [ScoreBuilder.LooseDirection], repeats: ScoreBuilder.Repeats) {
        self.builder = builder
        self.measures = measures
        self.parts = parts
        self.chords = chords
        self.loose = loose
        self.repeats = repeats
    }

    // MARK: Measures and pieces

    /// The measure holding `time` (the last one for the end).
    func measureIndex(at time: Rational) -> Int? {
        guard !measures.isEmpty else { return nil }
        var low = 0, high = measures.count - 1
        if time < measures[0].start { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if measures[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The measure that ends at `time`.
    func measureEnding(at time: Rational) -> Int? {
        guard let index = measureIndex(at: time) else { return nil }
        if measures[index].start == time { return index > 0 ? index - 1 : nil }
        return index
    }

    /// The measure that starts at `time`, or the next one.
    func measureStarting(at time: Rational) -> Int? {
        guard let index = measureIndex(at: time) else { return nil }
        if measures[index].start == time || time < measures[0].start { return index }
        return index + 1 < measures.count ? index + 1 : nil
    }

    /// Plain note values that add up to `length` (in whole notes).
    static func noteValues(_ length: Rational) -> [(log: Int, dots: Int)]? {
        var remaining = length
        var values: [(Int, Int)] = []
        while remaining > .zero && values.count < 8 {
            guard let log = (-2...10).first(where: { ScoreEvents.Duration(log: $0).unscaledLength <= remaining }) else {
                return nil
            }
            var dots = 0
            while dots < 3, ScoreEvents.Duration(log: log, dots: dots + 1).unscaledLength <= remaining { dots += 1 }
            values.append((log, dots))
            remaining = remaining - ScoreEvents.Duration(log: log, dots: dots).unscaledLength
        }
        return remaining.isZero ? values : nil
    }

    mutating func makePieces() {
        for (index, chord) in chords.enumerated() {
            guard let first = measureIndex(at: chord.moment.main) else { continue }
            let start = chord.moment.main
            if chord.isGrace || chord.length.isZero {
                pieces.append(Piece(chord: index, measure: first, onset: start - measures[first].start,
                                    length: .zero, values: [(chord.duration.log, chord.duration.dots)],
                                    first: true, last: true))
                continue
            }
            let end = start + chord.length
            var m = first
            var spans: [(measure: Int, from: Rational, to: Rational)] = []
            while m < measures.count, measures[m].start < end {
                let from = Swift.max(start, measures[m].start)
                let to = Swift.min(end, measures[m].end)
                if from < to { spans.append((m, from, to)) }
                m += 1
            }
            if spans.isEmpty { spans = [(first, start, end)] }
            for (i, span) in spans.enumerated() {
                let length = span.to - span.from
                var values = [(chord.duration.log, chord.duration.dots)]
                if spans.count > 1 {
                    values = Self.noteValues(length / tupletScale(chord))
                        ?? [Self.noteValues(length)?.first ?? (chord.duration.log, chord.duration.dots)]
                }
                if chord.kind == .measureRest { values = [] }
                pieces.append(Piece(chord: index, measure: span.measure, onset: span.from - measures[span.measure].start,
                                    length: length, values: values, first: i == 0, last: i == spans.count - 1))
            }
        }
        // Divisions per quarter note, so every length and position is whole.
        var lcm = 1
        func include(_ r: Rational) {
            let quarters = r * Rational(4)
            lcm = Rational.lcm(lcm, quarters.denominator)
        }
        for piece in pieces {
            include(piece.onset)
            include(piece.length)
            let chord = chords[piece.chord]
            if piece.values.count > 1, chord.kind != .measureRest {
                // Each tied value in the piece needs a whole number too.
                for value in piece.values {
                    include(ScoreEvents.Duration(log: value.log, dots: value.dots).unscaledLength * tupletScale(chord))
                }
            }
        }
        for measure in measures { include(measure.length) }
        for direction in loose { include(direction.moment.main) }
        for tempo in score.tempos { include(tempo.moment.main) }
        for mark in score.marks { include(mark.moment.main) }
        divisions = Swift.min(lcm, 1 << 20)
        for (index, piece) in pieces.enumerated() { piecesInMeasure[piece.measure, default: []].append(index) }
        for (index, chord) in chords.enumerated() {
            if let m = measureIndex(at: chord.moment.main) { chordsStartingIn[m, default: []].append(index) }
        }
        for (index, direction) in loose.enumerated() {
            if let m = measureIndex(at: direction.moment.main) { looseStartingIn[m, default: []].append(index) }
        }
    }

    /// A tuplet's factor; a multiplier above 1 (`r1*2`) isn't one.
    func tupletScale(_ chord: Chord) -> Rational {
        chord.duration.scale < .one && !chord.duration.scale.isZero ? chord.duration.scale : .one
    }

    func ticks(_ r: Rational) -> Int {
        Int((r * Rational(4 * divisions)).doubleValue.rounded())
    }

    // MARK: Document

    mutating func render() -> String {
        makePieces()
        for part in parts { voicesOfPart[part.id] = voiceNumbers(in: part) }
        var xml = XMLText()
        xml.line("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>")
        xml.line("<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        xml.open("score-partwise", ["version": "4.0"])
        writeHeader(&xml)
        writePartList(&xml)
        for (index, part) in parts.enumerated() {
            xml.open("part", ["id": part.id])
            for m in measures.indices {
                writeMeasure(&xml, part: part, partIndex: index, measure: m)
            }
            xml.close("part")
        }
        xml.close("score-partwise")
        return xml.text
    }

    func headerValue(_ key: String) -> String? {
        let value = (score.header[key] ?? builder.header[key])?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    func writeHeader(_ xml: inout XMLText) {
        let title = builder.header["title"].flatMap { $0.isEmpty ? nil : $0 }
        let opus = headerValue("opus")
        if title != nil || opus != nil {
            xml.open("work")
            if let opus { xml.leaf("work-number", opus) }
            if let title { xml.leaf("work-title", title) }
            xml.close("work")
        }
        if let piece = score.header["piece"].flatMap({ $0.isEmpty ? nil : $0 }) ?? headerValue("subtitle") {
            xml.leaf("movement-title", piece)
        }
        xml.open("identification")
        for (key, type) in [("composer", "composer"), ("poet", "lyricist"), ("arranger", "arranger")] {
            if let value = headerValue(key) { xml.leaf("creator", value, ["type": type]) }
        }
        if let rights = headerValue("copyright") { xml.leaf("rights", rights) }
        xml.open("encoding")
        xml.leaf("software", writer.software)
        xml.leaf("encoding-date", writer.date)
        xml.empty("supports", ["element": "accidental", "type": "no"])
        xml.empty("supports", ["element": "stem", "type": "no"])
        xml.close("encoding")
        xml.close("identification")
        if let paper = score.paper, paper.width > 0, paper.height > 0, paper.outputScale > 0 {
            // Tenths: 10 per staff space, 40 for the staff's height.
            func tenths(_ spaces: Double) -> String { Self.number(spaces * 10) }
            xml.open("defaults")
            xml.open("scaling")
            xml.leaf("millimeters", Self.number(paper.outputScale * 4))
            xml.leaf("tenths", "40")
            xml.close("scaling")
            xml.open("page-layout")
            xml.leaf("page-height", tenths(paper.height))
            xml.leaf("page-width", tenths(paper.width))
            xml.open("page-margins", ["type": "both"])
            xml.leaf("left-margin", tenths(paper.left))
            xml.leaf("right-margin", tenths(paper.right))
            xml.leaf("top-margin", tenths(paper.top))
            xml.leaf("bottom-margin", tenths(paper.bottom))
            xml.close("page-margins")
            xml.close("page-layout")
            xml.close("defaults")
        }
        writeCredits(&xml)
    }

    /// The titles as text on the first page, which is where programs such as
    /// Dorico read the composer and lyricist from. Placed as LilyPond's
    /// default title block: title and subtitle centred, poet on the left,
    /// composer and arranger on the right, copyright at the foot.
    func writeCredits(_ xml: inout XMLText) {
        let paper = score.paper.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let top = paper.map { ($0.height - $0.top) * 10 } ?? 0
        let left = paper.map { $0.left * 10 } ?? 0
        let right = paper.map { ($0.width - $0.right) * 10 } ?? 0
        let center = paper.map { $0.width * 5 } ?? 0
        let title = builder.header["title"].flatMap { $0.isEmpty ? nil : $0 }
        let subtitle = score.header["piece"].flatMap { $0.isEmpty ? nil : $0 } ?? headerValue("subtitle")
        let credits: [(type: String, text: String?, x: Double, y: Double, justify: String, valign: String, size: String)] = [
            ("title", title, center, top, "center", "top", "22"),
            ("subtitle", subtitle, center, top - 80, "center", "top", "16"),
            ("lyricist", headerValue("poet"), left, top - 150, "left", "top", "11"),
            ("composer", headerValue("composer"), right, top - 150, "right", "top", "11"),
            ("arranger", headerValue("arranger"), right, top - 190, "right", "top", "11"),
            ("rights", headerValue("copyright"), center, paper.map { $0.bottom * 10 } ?? 0, "center", "bottom", "9"),
        ]
        for credit in credits {
            guard let text = credit.text else { continue }
            xml.open("credit", ["page": "1"])
            xml.leaf("credit-type", credit.type)
            if paper != nil {
                xml.leaf("credit-words", text, ["default-x": Self.number(credit.x), "default-y": Self.number(credit.y),
                                                "justify": credit.justify, "valign": credit.valign,
                                                "font-size": credit.size])
            } else {
                xml.leaf("credit-words", text, ["justify": credit.justify, "valign": credit.valign])
            }
            xml.close("credit")
        }
    }

    var writer: MusicXMLWriter { builder.writer }

    func writePartList(_ xml: inout XMLText) {
        xml.open("part-list")
        // Each group's first and last part.
        var span: [String: (first: Int, last: Int)] = [:]
        for (index, part) in parts.enumerated() {
            for group in part.groups {
                span[group] = (span[group]?.first ?? index, index)
            }
        }
        var channel = 0
        for (index, part) in parts.enumerated() {
            for (depth, group) in part.groups.enumerated() where span[group]?.first == index {
                let context = score.contexts[group]
                xml.open("part-group", ["type": "start", "number": "\(depth + 1)"])
                if let name = context?.instrumentName, !name.isEmpty { xml.leaf("group-name", name) }
                let symbol: String
                switch context?.name {
                case "PianoStaff", "GrandStaff": symbol = "brace"
                case "InnerStaffGroup", "InnerChoirStaff": symbol = "square"
                default: symbol = "bracket"
                }
                xml.leaf("group-symbol", symbol)
                xml.leaf("group-barline", context?.name == "ChoirStaff" || context?.name == "InnerChoirStaff" ? "no" : "yes")
                xml.close("part-group")
            }
            xml.open("score-part", ["id": part.id])
            xml.leaf("part-name", part.name)
            if !part.abbreviation.isEmpty { xml.leaf("part-abbreviation", part.abbreviation) }
            if let props = score.properties[part.staves[0]]?.first, !props.midiInstrument.isEmpty {
                let id = "\(part.id)-I1"
                xml.open("score-instrument", ["id": id])
                xml.leaf("instrument-name", props.midiInstrument)
                xml.close("score-instrument")
                xml.open("midi-instrument", ["id": id])
                channel += 1
                if channel == 10 { channel += 1 }
                if channel <= 16 { xml.leaf("midi-channel", "\(channel)") }
                if let program = props.midiProgram { xml.leaf("midi-program", "\(program + 1)") }
                xml.close("midi-instrument")
            }
            xml.close("score-part")
            for (depth, group) in part.groups.enumerated().reversed() where span[group]?.last == index {
                xml.empty("part-group", ["type": "stop", "number": "\(depth + 1)"])
            }
        }
        xml.close("part-list")
    }

    // MARK: Attributes

    func staffNumber(_ staff: String, in part: ScoreBuilder.Part) -> Int {
        (part.staves.firstIndex(of: staff) ?? 0) + 1
    }

    static func mode(tonic: ScoreEvents.Pitch, fifths: Int) -> String {
        let base = [0, 2, 4, -1, 1, 3, 5][tonic.notename]
        let tonicFifths = base + Int((tonic.alteration * Rational(14)).doubleValue.rounded())
        switch tonicFifths - fifths {
        case 0: return "major"
        case 3: return "minor"
        case 2: return "dorian"
        case 4: return "phrygian"
        case -1: return "lydian"
        case 1: return "mixolydian"
        case 5: return "locrian"
        default: return "none"
        }
    }

    static func numbered(_ number: Int?) -> KeyValuePairs<String, String> {
        if let number { return ["number": "\(number)"] }
        return [:]
    }

    func writeKey(_ xml: inout XMLText, _ key: ScoreEvents.Key?, number: Int?) {
        let fifths = key?.fifths ?? 0
        xml.open("key", Self.numbered(number))
        xml.leaf("fifths", "\(fifths)")
        if let key { xml.leaf("mode", Self.mode(tonic: key.tonic, fifths: fifths)) }
        xml.close("key")
    }

    func writeClef(_ xml: inout XMLText, _ props: ScoreEvents.StaffProperties, number: Int?) {
        xml.open("clef", Self.numbered(number))
        let glyph = props.clefGlyph
        let line = props.clefPosition / 2 + 3
        if glyph.contains("percussion") {
            xml.leaf("sign", "percussion")
        } else if glyph.contains("tab") {
            xml.leaf("sign", "TAB")
        } else {
            let sign = glyph.contains("F") ? "F" : glyph.contains("C") ? "C" : "G"
            xml.leaf("sign", sign)
            xml.leaf("line", "\(line)")
        }
        let octaves = props.clefTransposition / 7
        if octaves != 0 { xml.leaf("clef-octave-change", "\(octaves)") }
        xml.close("clef")
    }

    func writeTime(_ xml: inout XMLText, _ time: (Int, Int), style: String, visible: Bool = true) {
        var attrs: KeyValuePairs<String, String> = [:]
        if style == "C" && time == (4, 4) { attrs = ["symbol": "common"] }
        if style == "C" && time == (2, 2) { attrs = ["symbol": "cut"] }
        if !visible { attrs = ["print-object": "no"] }
        xml.open("time", attrs)
        xml.leaf("beats", "\(time.0)")
        xml.leaf("beat-type", "\(time.1)")
        xml.close("time")
    }

    func writeTranspose(_ xml: inout XMLText, _ pitch: ScoreEvents.Pitch) {
        guard pitch.steps != 0 || pitch.semitones != 0 else { return }
        let octaves = pitch.steps / 7
        xml.open("transpose")
        xml.leaf("diatonic", "\(pitch.steps - octaves * 7)")
        xml.leaf("chromatic", "\(pitch.semitones - octaves * 12)")
        if octaves != 0 { xml.leaf("octave-change", "\(octaves)") }
        xml.close("transpose")
    }

    /// Key, clef and time changes in `part` within [from, to).
    struct Change {
        var at: Rational
        var keys: [Int: ScoreEvents.Key] = [:]
        var clefs: [Int: ScoreEvents.StaffProperties] = [:]
        var time: (Int, Int)?
    }

    func changes(in part: ScoreBuilder.Part, measure m: Int) -> [Change] {
        let measure = measures[m]
        var byTime: [Rational: Change] = [:]
        for (s, staff) in part.staves.enumerated() {
            for key in score.keys where key.staff == staff {
                let at = key.moment.main
                guard at > .zero, at >= measure.start, at < measure.end else { continue }
                byTime[at, default: Change(at: at)].keys[s + 1] = key
            }
            var previous: ScoreEvents.StaffProperties?
            for props in score.properties[staff] ?? [] {
                defer { previous = props }
                guard let before = previous, before.clefGlyph != props.clefGlyph || before.clefPosition != props.clefPosition
                        || before.clefTransposition != props.clefTransposition else { continue }
                let at = props.moment.main
                guard at >= measure.start, at < measure.end else { continue }
                byTime[at, default: Change(at: at)].clefs[s + 1] = props
            }
        }
        if m > 0, let time = measure.time, measures[m - 1].time.map({ $0 != time }) ?? true {
            byTime[measure.start, default: Change(at: measure.start)].time = time
        }
        return byTime.values.sorted { $0.at < $1.at }
    }

    func writeChange(_ xml: inout XMLText, _ change: Change, part: ScoreBuilder.Part) {
        xml.open("attributes")
        for (number, key) in change.keys.sorted(by: { $0.key < $1.key }) {
            writeKey(&xml, key, number: part.staves.count > 1 ? number : nil)
        }
        if let time = change.time {
            let props = score.properties[part.staves[0]]?.first
            writeTime(&xml, time, style: props?.timeSignatureStyle ?? "", visible: props?.timeSignatureVisible ?? true)
        }
        for (number, props) in change.clefs.sorted(by: { $0.key < $1.key }) {
            writeClef(&xml, props, number: part.staves.count > 1 ? number : nil)
        }
        xml.close("attributes")
    }

    func writeFirstAttributes(_ xml: inout XMLText, part: ScoreBuilder.Part) {
        xml.open("attributes")
        xml.leaf("divisions", "\(divisions)")
        let keys = part.staves.map { staff in score.keys.first { $0.staff == staff && !($0.moment.main > .zero) } }
        let fifths = keys.map { $0?.fifths ?? 0 }
        if Set(fifths).count <= 1 {
            writeKey(&xml, keys.first ?? nil, number: nil)
        } else {
            for (index, key) in keys.enumerated() { writeKey(&xml, key, number: index + 1) }
        }
        if let time = measures.first?.time ?? (measures.first.map { _ in (4, 4) }) {
            let props = score.properties[part.staves[0]]?.first
            writeTime(&xml, time, style: props?.timeSignatureStyle ?? "", visible: props?.timeSignatureVisible ?? true)
        }
        if part.staves.count > 1 { xml.leaf("staves", "\(part.staves.count)") }
        for (index, staff) in part.staves.enumerated() {
            if let props = score.properties[staff]?.first {
                writeClef(&xml, props, number: part.staves.count > 1 ? index + 1 : nil)
            }
        }
        if let pitch = score.properties[part.staves[0]]?.first?.transposition { writeTranspose(&xml, pitch) }
        xml.close("attributes")
    }

    // MARK: Measures

    struct Item {
        var onset: Rational
        var grace: Rational
        var stream: Int
        var order: Int
        var length: Rational
        var xml: XMLText
    }

    func writeMeasure(_ xml: inout XMLText, part: ScoreBuilder.Part, partIndex: Int, measure m: Int) {
        let measure = measures[m]
        var attrs: KeyValuePairs<String, String> = ["number": "\(measure.number)"]
        if measure.implicit { attrs = ["number": "\(measure.number)", "implicit": "yes"] }
        xml.open("measure", attrs)
        if m > 0, let forced = score.breaks.filter({ measureStarting(at: $0.moment.main) == m }).nilIfEmpty {
            xml.empty("print", forced.contains { $0.page } ? ["new-page": "yes"] : ["new-system": "yes"])
        }
        writeLeftBarline(&xml, measure: m)
        let changes = changes(in: part, measure: m)
        if m == 0 { writeFirstAttributes(&xml, part: part) }
        var items: [Item] = []
        for change in changes where !(m == 0 && change.at.isZero) {
            var x = XMLText()
            writeChange(&x, change, part: part)
            items.append(Item(onset: change.at - measure.start, grace: .zero, stream: 0, order: 0, length: .zero, xml: x))
        }

        // Voices in this part, numbered in order of their first note.
        let voiceNumbers = voicesOfPart[part.id] ?? [:]
        if partIndex == 0 { items += scoreDirections(measure: m) }
        items += directionItems(part: part, measure: m, voices: voiceNumbers)
        var staffHasNotes = Set<String>()
        for index in piecesInMeasure[m] ?? [] {
            let piece = pieces[index]
            let chord = chords[piece.chord]
            guard part.staves.contains(chord.staff), let voice = voiceNumbers[chord.voice] else { continue }
            staffHasNotes.insert(chord.staff)
            items.append(Item(onset: piece.onset, grace: chord.moment.grace, stream: voice, order: 2,
                              length: piece.length, xml: noteXML(piece, chord: chord, part: part, voice: voice)))
        }
        // An empty staff (a voice moved to the other hand, or only skips): a hidden rest.
        for staff in part.staves where !staffHasNotes.contains(staff) {
            var x = XMLText()
            x.open("note", ["print-object": "no"])
            x.empty("rest", ["measure": "yes"])
            x.leaf("duration", "\(ticks(measure.length))")
            let voice = (staffNumber(staff, in: part) - 1) * 4 + 1
            x.leaf("voice", "\(voice)")
            if part.staves.count > 1 { x.leaf("staff", "\(staffNumber(staff, in: part))") }
            x.close("note")
            items.append(Item(onset: .zero, grace: .zero, stream: 1000 + voice, order: 2, length: measure.length, xml: x))
        }

        items.sort {
            ($0.stream, $0.onset, $0.grace, $0.order) < ($1.stream, $1.onset, $1.grace, $1.order)
        }
        var cursor = Rational.zero
        for item in items {
            if item.onset > cursor {
                xml.open("forward")
                xml.leaf("duration", "\(ticks(item.onset - cursor))")
                xml.close("forward")
            } else if item.onset < cursor {
                xml.open("backup")
                xml.leaf("duration", "\(ticks(cursor - item.onset))")
                xml.close("backup")
            }
            xml.append(item.xml)
            cursor = item.onset + item.length
        }
        writeRightBarline(&xml, measure: m)
        xml.close("measure")
    }

    /// Voices numbered by the staff of their first note, as is usual:
    /// 1–4 on the first staff, 5–8 on the second ...
    func voiceNumbers(in part: ScoreBuilder.Part) -> [String: Int] {
        var numbers: [String: Int] = [:]
        var countOnStaff: [Int: Int] = [:]
        for chord in chords where part.staves.contains(chord.staff) && numbers[chord.voice] == nil {
            let staff = staffNumber(chord.staff, in: part) - 1
            let count = (countOnStaff[staff] ?? 0) + 1
            countOnStaff[staff] = count
            numbers[chord.voice] = count <= 4 ? staff * 4 + count : part.staves.count * 4 + count
        }
        return numbers
    }

    // MARK: Directions

    static let dynamics: Set<String> = ["p", "pp", "ppp", "pppp", "ppppp", "pppppp", "f", "ff", "fff", "ffff",
                                        "fffff", "ffffff", "mp", "mf", "sf", "sfp", "sfpp", "fp", "rf", "rfz",
                                        "sfz", "sffz", "fz", "n", "pf", "sfzp"]

    func directionXML(_ event: Event, voice: Int?, staff: Int?) -> XMLText? {
        var x = XMLText()
        let above = event.direction == 1
        let below = event.direction == -1
        func open(_ defaultAbove: Bool) {
            x.open("direction", ["placement": above ? "above" : below ? "below" : defaultAbove ? "above" : "below"])
            x.open("direction-type")
        }
        func close() {
            x.close("direction-type")
            if let voice { x.leaf("voice", "\(voice)") }
            if let staff { x.leaf("staff", "\(staff)") }
            x.close("direction")
        }
        switch event.kind {
        case "absolute-dynamic-event":
            guard let text = event.text, !text.isEmpty else { return nil }
            open(false)
            x.open("dynamics")
            if Self.dynamics.contains(text) { x.empty(text) } else { x.leaf("other-dynamics", text) }
            x.close("dynamics")
            close()
        case "crescendo-event", "decrescendo-event":
            open(false)
            let type = event.spanDirection == 1 ? "stop" : event.kind == "crescendo-event" ? "crescendo" : "diminuendo"
            x.empty("wedge", ["type": type, "number": "1"])
            close()
        case "text-script-event":
            guard let text = event.text, !text.isEmpty else { return nil }
            open(true)
            x.leaf("words", text)
            close()
        default:
            return nil
        }
        return x
    }

    func isDirection(_ event: Event) -> Bool {
        ["absolute-dynamic-event", "crescendo-event", "decrescendo-event", "text-script-event"].contains(event.kind)
    }

    /// Dynamics, hairpins and texts of the part's voices in measure `m`;
    /// a hairpin left open ends at the next dynamic.
    func directionItems(part: ScoreBuilder.Part, measure m: Int, voices: [String: Int]) -> [Item] {
        var items: [Item] = []
        let measure = measures[m]
        func add(_ events: [Event], moment: Moment, voice: String, staff: String) {
            guard moment.main >= measure.start, moment.main < measure.end || (m == measures.count - 1 && moment.main == measure.end),
                  part.staves.contains(staff) else { return }
            let number = voices[voice]
            for event in events where isDirection(event) {
                guard let x = directionXML(event, voice: number, staff: part.staves.count > 1 ? staffNumber(staff, in: part) : nil) else { continue }
                items.append(Item(onset: moment.main - measure.start, grace: moment.grace, stream: number ?? 0,
                                  order: 1, length: .zero, xml: x))
            }
        }
        for index in chordsStartingIn[m] ?? [] {
            let chord = chords[index]
            add(chord.events, moment: chord.moment, voice: chord.voice, staff: chord.staff)
        }
        for index in looseStartingIn[m] ?? [] {
            let direction = loose[index]
            add(direction.events, moment: direction.moment, voice: direction.voice, staff: direction.staff)
        }
        return items
    }

    static func markLabel(_ number: Int) -> String {
        // LilyPond's default letters skip I.
        let letters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
        var n = Swift.max(1, number) - 1
        var label = ""
        repeat {
            label = String(letters[n % letters.count]) + label
            n = n / letters.count - 1
        } while n >= 0
        return label
    }

    func scoreDirections(measure m: Int) -> [Item] {
        let measure = measures[m]
        var items: [Item] = []
        func inside(_ moment: Moment) -> Bool { moment.main >= measure.start && moment.main < measure.end }
        for tempo in score.tempos where inside(tempo.moment) {
            var x = XMLText()
            x.open("direction", ["placement": "above"])
            if !tempo.text.isEmpty {
                x.open("direction-type")
                x.leaf("words", tempo.text, ["font-weight": "bold"])
                x.close("direction-type")
            }
            if let unit = tempo.unit, let count = tempo.count, let name = Self.typeName(unit.log) {
                x.open("direction-type")
                x.open("metronome")
                x.leaf("beat-unit", name)
                for _ in 0..<unit.dots { x.empty("beat-unit-dot") }
                x.leaf("per-minute", "\(count)")
                x.close("metronome")
                x.close("direction-type")
            }
            if let unit = tempo.unit, let count = tempo.count {
                let quarters = (unit.length * Rational(4) * Rational(count)).doubleValue
                x.leaf("staff", "1")
                x.empty("sound", ["tempo": Self.number(quarters)])
            } else {
                x.leaf("staff", "1")
            }
            x.close("direction")
            if tempo.text.isEmpty && tempo.count == nil { continue }
            items.append(Item(onset: tempo.moment.main - measure.start, grace: .zero, stream: 0, order: 1,
                              length: .zero, xml: x))
        }
        for mark in score.marks where inside(mark.moment) {
            let label = mark.label.isEmpty ? mark.number.map(Self.markLabel) ?? "" : mark.label
            guard !label.isEmpty else { continue }
            var x = XMLText()
            x.open("direction", ["placement": "above"])
            x.open("direction-type")
            x.leaf("rehearsal", Int(label).map(Self.markLabel) ?? label)
            x.close("direction-type")
            x.leaf("staff", "1")
            x.close("direction")
            items.append(Item(onset: mark.moment.main - measure.start, grace: .zero, stream: 0, order: 1,
                              length: .zero, xml: x))
        }
        return items
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    // MARK: Notes

    static func typeName(_ log: Int) -> String? {
        let names = [-2: "long", -1: "breve", 0: "whole", 1: "half", 2: "quarter", 3: "eighth", 4: "16th",
                     5: "32nd", 6: "64th", 7: "128th", 8: "256th", 9: "512th", 10: "1024th"]
        return names[log]
    }

    static let articulations: [String: String] = [
        "accent": "accent", "staccato": "staccato", "tenuto": "tenuto", "staccatissimo": "staccatissimo",
        "marcato": "strong-accent", "portato": "detached-legato", "stress": "stress", "unstress": "unstress",
    ]
    static let ornaments: [String: String] = [
        "trill": "trill-mark", "prall": "inverted-mordent", "mordent": "mordent", "turn": "turn",
        "reverseturn": "inverted-turn",
    ]
    static let technical: [String: String] = [
        "upbow": "up-bow", "downbow": "down-bow", "flageolet": "harmonic", "stopped": "stopped",
        "open": "open", "thumb": "thumb-position", "snappizzicato": "snap-pizzicato",
    ]
    static let fermatas: [String: String] = [
        "fermata": "normal", "shortfermata": "angled", "longfermata": "square", "verylongfermata": "square",
        "henzeshortfermata": "angled", "henzelongfermata": "square",
    ]

    func notationsXML(_ events: [Event], notes: [ScoreBuilder.Note], noteIndex: Int, piece: Piece,
                      chord: Chord) -> XMLText? {
        var x = XMLText()
        var articulation = XMLText(), ornament = XMLText(), technical = XMLText()
        var any = false
        let note = notes.isEmpty ? nil : notes[noteIndex]
        if let note {
            if note.tieStop && piece.first || !piece.first { x.empty("tied", ["type": "stop"]); any = true }
            if note.tieStart && piece.last || !piece.last { x.empty("tied", ["type": "start"]); any = true }
        }
        let placement: (Event) -> KeyValuePairs<String, String> = { event in
            event.direction == 1 ? ["placement": "above"] : event.direction == -1 ? ["placement": "below"] : [:]
        }
        for event in events {
            switch event.kind {
            case "slur-event", "phrasing-slur-event":
                let number = event.kind == "slur-event" ? "1" : "2"
                if event.spanDirection == -1 && piece.first { x.empty("slur", ["type": "start", "number": number]); any = true }
                if event.spanDirection == 1 && piece.last { x.empty("slur", ["type": "stop", "number": number]); any = true }
            case "tuplet-span-event":
                if event.spanDirection == -1 && piece.first { x.empty("tuplet", ["type": "start", "bracket": "yes"]); any = true }
                if event.spanDirection == 1 && piece.last { x.empty("tuplet", ["type": "stop"]); any = true }
            case "articulation-event" where piece.first:
                guard let type = event.articulation else { continue }
                if let name = Self.articulations[type] {
                    articulation.empty(name, placement(event))
                } else if let name = Self.ornaments[type] {
                    ornament.empty(name, placement(event))
                } else if let name = Self.technical[type] {
                    technical.empty(name, placement(event))
                } else if let shape = Self.fermatas[type] {
                    x.leaf("fermata", shape, event.direction == -1 ? ["type": "inverted"] : ["type": "upright"])
                    any = true
                }
            case "breathing-event" where piece.last:
                articulation.empty("breath-mark")
            case "fingering-event" where piece.first:
                if let digit = event.digit { technical.leaf("fingering", "\(digit)", placement(event)) }
            case "arpeggio-event" where piece.first:
                x.empty("arpeggiate"); any = true
            default:
                continue
            }
        }
        if !ornament.text.isEmpty { x.open("ornaments"); x.append(ornament); x.close("ornaments"); any = true }
        if !technical.text.isEmpty { x.open("technical"); x.append(technical); x.close("technical"); any = true }
        if !articulation.text.isEmpty { x.open("articulations"); x.append(articulation); x.close("articulations"); any = true }
        guard any else { return nil }
        var wrapped = XMLText()
        wrapped.open("notations")
        wrapped.append(x)
        wrapped.close("notations")
        return wrapped
    }

    func noteXML(_ piece: Piece, chord: Chord, part: ScoreBuilder.Part, voice: Int) -> XMLText {
        var xml = XMLText()
        // A piece made of several tied values (a note across a bar line
        // that no single value fits) is written value by value.
        let values = piece.values.isEmpty ? [(log: Int.min, dots: 0)] : piece.values
        var offset = Rational.zero
        for (v, value) in values.enumerated() {
            let length: Rational
            if chord.kind == .measureRest || values.count == 1 {
                length = piece.length
            } else {
                length = ScoreEvents.Duration(log: value.log, dots: value.dots).unscaledLength * tupletScale(chord)
            }
            let sub = Piece(chord: piece.chord, measure: piece.measure, onset: piece.onset + offset, length: length,
                            values: [value], first: piece.first && v == 0, last: piece.last && v == values.count - 1)
            offset += length
            let count = chord.kind == .notes ? chord.notes.count : 1
            for n in 0..<count {
                xml.open("note", chord.hidden ? ["print-object": "no"] : [:])
                if chord.isGrace { xml.empty("grace") }
                if n > 0 { xml.empty("chord") }
                switch chord.kind {
                case .notes:
                    let pitch = chord.notes[n].pitch
                    xml.open("pitch")
                    xml.leaf("step", String(Array("CDEFGAB")[pitch.notename]))
                    let alter = (pitch.alteration * Rational(2)).doubleValue
                    if alter != 0 { xml.leaf("alter", Self.number(alter)) }
                    xml.leaf("octave", "\(pitch.octave + 4)")
                    xml.close("pitch")
                case .rest:
                    xml.empty("rest")
                case .measureRest:
                    xml.empty("rest", ["measure": "yes"])
                }
                if !chord.isGrace { xml.leaf("duration", "\(ticks(length))") }
                if chord.kind == .notes {
                    let note = chord.notes[n]
                    if note.tieStop && sub.first || !sub.first { xml.empty("tie", ["type": "stop"]) }
                    if note.tieStart && sub.last || !sub.last { xml.empty("tie", ["type": "start"]) }
                }
                xml.leaf("voice", "\(voice)")
                if chord.kind != .measureRest, let name = Self.typeName(value.log) {
                    xml.leaf("type", name)
                    for _ in 0..<value.dots { xml.empty("dot") }
                }
                let scale = chord.duration.scale
                if chord.kind != .measureRest, !scale.isZero, scale < .one {
                    xml.open("time-modification")
                    xml.leaf("actual-notes", "\(scale.denominator)")
                    xml.leaf("normal-notes", "\(scale.numerator)")
                    xml.close("time-modification")
                }
                if part.staves.count > 1 { xml.leaf("staff", "\(staffNumber(chord.staff, in: part))") }
                if n == 0, piece.first && piece.last, values.count == 1 {
                    for (level, value) in chord.beams.enumerated() { xml.leaf("beam", value, ["number": "\(level + 1)"]) }
                }
                var events = n == 0 ? chord.events + chord.endEvents : []
                if chord.kind == .notes { events += chord.notes[n].events }
                if n > 0 { events += chord.events.filter { $0.kind == "arpeggio-event" } }
                let restNotes: [ScoreBuilder.Note] = chord.kind == .notes ? chord.notes : []
                if let notations = notationsXML(events, notes: restNotes, noteIndex: n, piece: sub, chord: chord) {
                    xml.append(notations)
                }
                if n == 0 && sub.first {
                    for lyric in chord.lyrics {
                        xml.open("lyric", ["number": "\(lyric.number)"])
                        xml.leaf("syllabic", lyric.syllabic)
                        xml.leaf("text", lyric.text)
                        if lyric.extend { xml.empty("extend") }
                        xml.close("lyric")
                    }
                }
                xml.close("note")
            }
        }
        return xml
    }

    // MARK: Bar lines

    static func barStyle(_ glyph: String) -> String? {
        switch glyph {
        case "|.", ":|.", ":|.|:", ":..:", ":|.:": return "light-heavy"
        case "||": return "light-light"
        case ".|", ".|:": return "heavy-light"
        case "..": return "heavy-heavy"
        case ".": return "heavy"
        case "!": return "dashed"
        case ";": return "dotted"
        case "'": return "tick"
        case "": return "none"
        default: return nil
        }
    }

    func writeLeftBarline(_ xml: inout XMLText, measure m: Int) {
        let forward = repeats.forward.contains { measureStarting(at: $0) == m }
        let ending = repeats.endingStart.first { measureStarting(at: $0.key) == m }?.value
        guard forward || ending != nil else { return }
        xml.open("barline", ["location": "left"])
        if forward { xml.leaf("bar-style", "heavy-light") }
        if let ending {
            let text = ending.split(separator: ",").map { "\($0.trimmingCharacters(in: .whitespaces))." }.joined(separator: ", ")
            xml.leaf("ending", text, ["number": ending, "type": "start"])
        }
        if forward { xml.empty("repeat", ["direction": "forward"]) }
        xml.close("barline")
    }

    func writeRightBarline(_ xml: inout XMLText, measure m: Int) {
        let end = measures[m].end
        let isLast = m == measures.count - 1
        let backward = repeats.backward.first { measureEnding(at: $0.key) == m || isLast && $0.key >= end }
        let endingStop = repeats.endingStop.first { measureEnding(at: $0.key) == m || isLast && $0.key >= end }
        var glyph = score.barlines.last { $0.moment.main == end && !$0.glyph.contains(":") }?.glyph
        if glyph == nil, isLast, backward == nil { glyph = score.finalBar }
        let style = glyph.flatMap(Self.barStyle)
        guard backward != nil || endingStop != nil || style != nil else { return }
        xml.open("barline", ["location": "right"])
        if backward != nil { xml.leaf("bar-style", "light-heavy") } else if let style { xml.leaf("bar-style", style) }
        if let endingStop {
            xml.empty("ending", ["number": endingStop.value, "type": backward != nil ? "stop" : "discontinue"])
        }
        if let backward {
            if backward.value > 2 {
                xml.empty("repeat", ["direction": "backward", "times": "\(backward.value)"])
            } else {
                xml.empty("repeat", ["direction": "backward"])
            }
        }
        xml.close("barline")
    }
}
