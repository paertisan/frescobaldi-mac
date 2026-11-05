import Foundation
import Testing
@testable import FrescobaldiCore

struct RationalTests {
    @Test func arithmetic() {
        #expect(Rational(2, 4) == Rational(1, 2))
        #expect(Rational(1, 4) + Rational(1, 6) == Rational(5, 12))
        #expect(Rational(3, 4) - Rational(1) == Rational(-1, 4))
        #expect(Rational(2, 3) * Rational(3, 8) == Rational(1, 4))
        #expect(Rational(1, 2) / Rational(1, 4) == Rational(2))
        #expect(Rational(-1, 4) < .zero)
        #expect(Rational("-13/4") == Rational(-13, 4))
        #expect(Rational("3") == Rational(3))
        #expect(Rational("x") == nil)
    }

    @Test func durations() {
        typealias D = ScoreEvents.Duration
        #expect(D(log: 2).length == Rational(1, 4))
        #expect(D(log: 2, dots: 1).length == Rational(3, 8))
        #expect(D(log: 3, scale: Rational(2, 3)).length == Rational(1, 12))
        #expect(D(log: -1).length == Rational(2))
        #expect(D(log: 1, dots: 1, scale: Rational(4)).length == Rational(3))
    }

    @Test func pitches() {
        let bes = ScoreEvents.Pitch(octave: -1, notename: 6, alteration: Rational(-1, 2))
        #expect(bes.steps == -1)
        #expect(bes.semitones == -2)
    }
}

struct ScoreEventsTests {
    @Test func parsesRecords() {
        let text = """
            fmac-events\t1
            header\ttitle\tSong
            score\t1\t1
            staff\t3\tStaff\tv\t1
            props\t3\t0,0\tclefs.G\t-2\t0\tFlute\tFl.\tflute\t73\t0,0,0\tC
            bar\t0,0\t1\t-1/4,0\t1,0\t4/4
            ev\t5\t3\t0,0\tnote-event\t2,0,1\t1,4,0\t\t\t\t\t\t
            ev\t5\t3\t0,0\tarticulation-event\t\t\t\taccent\t\t\t1\t1
            lyric\t6\t0,0\tlyric-event\tUp\t5
            end\t1/4,0\t|.
            scoreheader\t1\tpiece\tFirst

            """
        let events = ScoreEvents(parsing: text)
        #expect(events.header["title"] == "Song")
        #expect(events.scores.count == 1)
        let score = events.scores[0]
        #expect(score.header["piece"] == "First")
        #expect(score.staves.map(\.contextID) == ["v"])
        #expect(score.properties["3"]?.first?.midiProgram == 73)
        #expect(score.bars.first?.position == Rational(-1, 4))
        #expect(score.bars.first?.timeSignature.map { [$0.0, $0.1] } == [4, 4])
        #expect(score.events.count == 2)
        #expect(score.events[0].pitch == ScoreEvents.Pitch(octave: 1, notename: 4))
        #expect(score.events[1].attached && score.events[1].direction == 1)
        #expect(score.lyrics.first?.voice == "5")
        #expect(score.end.main == Rational(1, 4))
        #expect(score.finalBar == "|.")
    }

    @Test func destinationsKeepLilyPondsSuffixes() {
        let files = ["score.midi", "score-1.midi", "score-2.midi"].map { URL(fileURLWithPath: "/tmp/out/" + $0) }
        let chosen = URL(fileURLWithPath: "/Users/me/Song.midi")
        #expect(ScoreExport.destinations(for: files, baseName: "score", first: chosen).map(\.path)
                == ["/Users/me/Song.midi", "/Users/me/Song-1.midi", "/Users/me/Song-2.midi"])
    }

    @Test func noteValuesAcrossBarLines() {
        let values = MusicXMLWriter.noteValues(Rational(5, 8))
        #expect(values?.map { [$0.log, $0.dots] } == [[1, 0], [3, 0]])
        #expect(MusicXMLWriter.noteValues(Rational(3, 4))?.map { [$0.log, $0.dots] } == [[1, 1]])
        #expect(MusicXMLWriter.noteValues(Rational(1, 12)) == nil)
    }
}

// MARK: - Engraving

private let exportLilyPond = LilyPondLocator.locate(userSetting: nil)

/// Exports scores with Resources/LilyPond/fmac-export.ly and fmac-midi.ly
/// and reads the MusicXML back. Needs LilyPond. FMAC_DUMP_XML=1 prints it,
/// FMAC_DUMP_XML=<folder> keeps the files there.
@Suite(.enabled(if: exportLilyPond != nil, "LilyPond isn't installed"))
struct MusicXMLExportTests {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LilyPond")

    func export(_ format: ScoreExport.Format, files: [String: String], main: String = "score.ly")
        async throws -> (ScoreExport.Output, [String], [Data]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let export = ScoreExport(format: format, lilypond: try #require(exportLilyPond),
                                 source: folder.appendingPathComponent(main), resources: Self.resources,
                                 folder: folder.appendingPathComponent("out"),
                                 writer: MusicXMLWriter(date: Date(timeIntervalSince1970: 0)))
        let outcome: Result<ScoreExport.Output, ScoreExport.Failure> = await withCheckedContinuation { continuation in
            export.start { continuation.resume(returning: $0) }
        }
        switch outcome {
        case let .success(output):
            let data = output.files.map { (try? Data(contentsOf: $0)) ?? Data() }
            let texts = data.map { String(decoding: $0, as: UTF8.self) }
            if let dump = ProcessInfo.processInfo.environment["FMAC_DUMP_XML"] {
                if dump.hasPrefix("/") {
                    // A folder: keep the files, to check with a schema.
                    for (url, contents) in zip(output.files, data) {
                        let name = main.replacingOccurrences(of: "/", with: "-") + "-" + UUID().uuidString.prefix(4)
                            + "-" + url.lastPathComponent
                        try? contents.write(to: URL(fileURLWithPath: dump).appendingPathComponent(name))
                    }
                } else {
                    for text in texts { print(text) }
                    print(output.result.log)
                }
            }
            return (output, texts, data)
        case let .failure(failure):
            Issue.record("export failed: \(failure)")
            throw failure
        }
    }

    func xml(_ text: String) throws -> XMLDocument {
        try XMLDocument(xmlString: text, options: [])
    }

    func strings(_ document: XMLDocument, _ path: String) throws -> [String] {
        try document.nodes(forXPath: path).map { $0.stringValue ?? "" }
    }

    func count(_ document: XMLDocument, _ path: String) throws -> Int {
        try document.nodes(forXPath: path).count
    }

    static let song = """
        \\version "2.24.0"
        \\header { title = "Song" composer = "Anon" poet = "Words" }
        melody = \\relative c'' {
          \\key g \\major \\time 3/4 \\tempo "Allegro" 4 = 120
          \\partial 4 d4 |
          \\repeat volta 2 { g4.->( a8) b4~\\p\\< | b4 \\tuplet 3/2 { c8 b a } g4\\f | }
          \\alternative { { d2. | } { \\grace e16 d2 r4 \\bar "|." } }
        }
        words = \\lyricmode { Up | sing a long -- er song now | we | go }
        \\score {
          <<
            \\new Staff \\with { instrumentName = "Voice" midiInstrument = "choir aahs" }
              { \\new Voice = "mel" \\melody }
            \\new Lyrics \\lyricsto "mel" \\words
            \\new PianoStaff \\with { instrumentName = "Piano" } <<
              \\new Staff = "rh" \\relative c' { \\key g \\major \\partial 4 r4 | << { b'2 c4 } \\\\ { g2 fis4 } >> | <g b d>2.-. | e2. | d2 r4 | }
              \\new Staff = "lh" \\relative c { \\clef bass \\key g \\major \\partial 4 r4 | g2. | R2. | c2. | g2 r4 | }
            >>
          >>
          \\layout { }
          \\midi { }
        }

        """

    @Test func song() async throws {
        let (output, texts, _) = try await export(.musicXML, files: ["score.ly": Self.song])
        #expect(output.files.map(\.lastPathComponent) == ["score.musicxml"])
        let doc = try xml(try #require(texts.first))
        #expect(try strings(doc, "//work-title") == ["Song"])
        #expect(try strings(doc, "//creator[@type='composer']") == ["Anon"])
        #expect(try strings(doc, "//creator[@type='lyricist']") == ["Words"])
        #expect(try strings(doc, "//score-part/part-name") == ["Voice", "Piano"])
        #expect(try strings(doc, "//score-part[@id='P1']//midi-program") == ["53"])
        // The pickup, then bars 1–4 (the repeat isn't played out).
        #expect(try strings(doc, "//part[@id='P1']/measure/@number") == ["0", "1", "2", "3", "4"])
        #expect(try strings(doc, "//part[@id='P1']/measure[1]/@implicit") == ["yes"])
        #expect(try strings(doc, "//part[@id='P2']/measure[1]/attributes/staves") == ["2"])
        #expect(try strings(doc, "//part[@id='P1']/measure[1]/attributes/key/fifths") == ["1"])
        #expect(try strings(doc, "//part[@id='P1']/measure[1]/attributes/time/beats") == ["3"])
        #expect(try strings(doc, "//part[@id='P2']/measure[1]/attributes/clef[@number='2']/sign") == ["F"])
        // Pitches, ties, tuplets, grace notes.
        let melody = try strings(doc, "//part[@id='P1']//note[not(rest)]/pitch").map { $0 }
        #expect(melody.first == "D5")
        #expect(try count(doc, "//part[@id='P1']//note/tie[@type='start']") == 1)
        #expect(try count(doc, "//part[@id='P1']//note/tie[@type='stop']") == 1)
        #expect(try count(doc, "//part[@id='P1']//time-modification") == 3)
        #expect(try count(doc, "//part[@id='P1']//tuplet[@type='start']") == 1)
        #expect(try count(doc, "//part[@id='P1']//tuplet[@type='stop']") == 1)
        #expect(try count(doc, "//part[@id='P1']//note[grace]") == 1)
        #expect(try count(doc, "//part[@id='P1']//slur") == 2)
        #expect(try count(doc, "//part[@id='P1']//accent") == 1)
        // Dynamics and the hairpin the f ends.
        #expect(try count(doc, "//part[@id='P1']//dynamics/p") == 1)
        #expect(try strings(doc, "//part[@id='P1']//wedge/@type") == ["crescendo", "stop"])
        #expect(try strings(doc, "//part[@id='P1']//sound/@tempo") == ["120"])
        #expect(try strings(doc, "//part[@id='P1']//words") == ["Allegro"])
        // Lyrics, with the hyphen and the second syllable's end.
        #expect(try strings(doc, "//part[@id='P1']//lyric/text") == ["Up", "sing", "a", "long", "er", "song", "now", "we", "go"])
        #expect(try strings(doc, "//part[@id='P1']//lyric/syllabic")[3...4] == ["begin", "end"])
        // Repeats and endings.
        #expect(try count(doc, "//part[@id='P1']/measure[@number='1']/barline[@location='left']/repeat[@direction='forward']") == 1)
        #expect(try strings(doc, "//part[@id='P1']/measure[@number='3']/barline/ending/@number") == ["1", "1"])
        #expect(try count(doc, "//part[@id='P1']/measure[@number='3']/barline/repeat[@direction='backward']") == 1)
        #expect(try strings(doc, "//part[@id='P1']/measure[@number='4']/barline[@location='left']/ending/@number") == ["2"])
        #expect(try strings(doc, "//part[@id='P1']/measure[@number='4']/barline[@location='right']/bar-style") == ["light-heavy"])
        // Piano: two voices in the right hand, a chord with staccato, the bass staff.
        #expect(try Set(strings(doc, "//part[@id='P2']//note/voice")).count >= 3)
        #expect(try count(doc, "//part[@id='P2']//note[chord]") == 2)
        #expect(try count(doc, "//part[@id='P2']//staccato") == 1)
        #expect(try count(doc, "//part[@id='P2']//note[staff='2' and not(rest)]") == 3)
        #expect(try count(doc, "//part[@id='P2']//rest[@measure='yes']") >= 1)
        // The triplet's beam, as LilyPond drew it.
        #expect(try strings(doc, "//part[@id='P1']//beam[@number='1']") == ["begin", "continue", "end"])
        // The page: A4 at staff size 20 (20 TeX points, 7.03 mm, for the
        // staff's height), and the titles on it.
        #expect(try strings(doc, "//defaults/scaling/millimeters") == ["7.0292"])
        let width = try #require(Double(try strings(doc, "//defaults/page-layout/page-width").first ?? ""))
        #expect(abs(width / 40 * 7.0292 - 210) < 0.1, "A4 is 210 mm wide")
        #expect(try strings(doc, "//credit[credit-type='composer']/credit-words") == ["Anon"])
        #expect(try strings(doc, "//credit[credit-type='title']/credit-words/@justify") == ["center"])
    }

    /// Paper size and margins, forced breaks, hidden meters and notes, and
    /// sixteenth beams with hooks.
    @Test func layoutAndHiddenThings() async throws {
        let score = """
            \\version "2.24.0"
            #(set! paper-alist (cons '("17x11" . (cons (* 17 in) (* 11 in))) paper-alist))
            \\paper { #(set-paper-size "17x11") top-margin = 18\\mm left-margin = 16\\mm }
            #(set-global-staff-size 16)
            \\layout { \\context { \\Staff \\omit TimeSignature } }
            \\new Staff \\relative c'' {
              \\time 3/4 c8. d16 e4 f | \\break
              \\hideNotes g2. \\unHideNotes | \\pageBreak
              a2. |
            }

            """
        let (_, texts, _) = try await export(.musicXML, files: ["score.ly": score])
        let doc = try xml(try #require(texts.first))
        // Staff size 16: 16 TeX points (1/72.27 in) = 5.6234 mm.
        #expect(try strings(doc, "//defaults/scaling/millimeters") == ["5.6234"])
        func mm(_ path: String) throws -> Double {
            (Double(try strings(doc, path).first ?? "") ?? 0) / 40 * 5.6234
        }
        #expect(abs(try mm("//page-width") - 17 * 25.4) < 0.1)
        #expect(abs(try mm("//page-height") - 11 * 25.4) < 0.1)
        #expect(abs(try mm("//page-margins/top-margin") - 18) < 0.1)
        #expect(abs(try mm("//page-margins/left-margin") - 16) < 0.1)
        #expect(try strings(doc, "//measure[@number='2']/print/@new-system") == ["yes"])
        #expect(try strings(doc, "//measure[@number='3']/print/@new-page") == ["yes"])
        #expect(try strings(doc, "//time/@print-object") == ["no"])
        #expect(try count(doc, "//measure[@number='2']/note[@print-object='no']") == 1)
        #expect(try count(doc, "//measure[@number='3']/note[@print-object='no']") == 0)
        #expect(try strings(doc, "//measure[@number='1']/note[1]/beam") == ["begin"])
        #expect(try strings(doc, "//measure[@number='1']/note[2]/beam") == ["end", "backward hook"])
    }

    /// A New Score project: the clarinet entered at concert pitch comes out
    /// written, with its transposition; the MIDI score adds no bars.
    @Test func newScoreProject() async throws {
        var spec = ScoreSpec()
        spec.apply(try #require(Ensemble.named("clarinet-piano")))
        spec.key = KeySignature(tonic: Pitch(1, 0), mode: .major)
        spec.time = TimeSignature(3, 4)
        spec.title = "Duo"
        var files: [String: String] = [:]
        for (path, contents) in ProjectTemplate.files(for: spec, name: "duo", version: LilyPondVersion(2, 24, 0)) {
            files[path] = contents
        }
        func fill(_ path: String, _ music: String) throws {
            let text = try #require(files[path])
            let range = try #require(text.range(of: "R2.*4 |"))
            files[path] = text.replacingCharacters(in: range, with: music)
        }
        try fill("music/clarinet.ily", "d4 e fis | g2. | a4 b cis | d2. |")
        try fill("music/piano.ily", "<d fis>2. | <e g> | <fis a> | <d fis a d> |")
        let (_, texts, _) = try await export(.musicXML, files: files, main: "duo.ly")
        let doc = try xml(try #require(texts.first))
        #expect(try strings(doc, "//work-title") == ["Duo"])
        #expect(try strings(doc, "//score-part/part-name") == ["Clarinet in B♭", "Piano"])
        #expect(try strings(doc, "//part[@id='P1']/measure/@number") == ["1", "2", "3", "4"])
        #expect(try strings(doc, "//part[@id='P1']//transpose/diatonic") == ["-1"])
        #expect(try strings(doc, "//part[@id='P1']//transpose/chromatic") == ["-2"])
        #expect(try strings(doc, "//part[@id='P1']//key/fifths") == ["4"])
        #expect(try strings(doc, "//part[@id='P1']//note/pitch").first == "E5")
        #expect(try strings(doc, "//part[@id='P2']//key/fifths") == ["2"])
        #expect(try count(doc, "//part[@id='P2']//note[not(chord) and not(rest)]") == 4)
        #expect(try count(doc, "//part[@id='P2']//note[staff='2']/rest[@measure='yes']") == 4)
    }

    /// Every New Score preset, with its empty bars: well-formed, and every
    /// part has every bar.
    @Test(arguments: Ensemble.all.map(\.id))
    func everyPreset(_ id: String) async throws {
        var spec = ScoreSpec()
        spec.apply(try #require(Ensemble.named(id)))
        spec.time = TimeSignature(3, 4)
        spec.pickup = "4"
        var files: [String: String] = [:]
        for (path, contents) in ProjectTemplate.files(for: spec, name: id, version: LilyPondVersion(2, 24, 0),
                                                       resources: Self.resources.deletingLastPathComponent()) {
            files[path] = contents
        }
        let (_, texts, _) = try await export(.musicXML, files: files, main: ProjectTemplate.mainFileName(name: id))
        let doc = try xml(try #require(texts.first))
        let parts = try count(doc, "//part")
        #expect(parts > 0)
        #expect(try count(doc, "//score-part") == parts)
        #expect(try count(doc, "//measure") == parts * 5, "\(id): a pickup and four bars in each part")
    }

    @Test func midiFromTheScoresMidiBlock() async throws {
        let (output, _, _) = try await export(.midi, files: ["score.ly": Self.song])
        #expect(!output.addedMIDIBlock)
        #expect(output.files.map(\.lastPathComponent) == ["score.midi"])
    }

    /// A score without \midi still exports, with its repeat played out.
    @Test func midiWithoutAMidiBlock() async throws {
        let plain = """
            \\version "2.24.0"
            \\score { \\relative c'' { \\repeat volta 2 { c4 d e f } g1 } \\layout { } }

            """
        let unfolded = """
            \\version "2.24.0"
            \\score { \\unfoldRepeats \\relative c'' { \\repeat volta 2 { c4 d e f } g1 } \\midi { } }

            """
        let (output, _, made) = try await export(.midi, files: ["score.ly": plain])
        #expect(output.addedMIDIBlock)
        #expect(made.count == 1 && made[0].starts(with: Data("MThd".utf8)))
        let (_, _, byHand) = try await export(.midi, files: ["score.ly": unfolded])
        #expect(made == byHand)
    }

    @Test func nothingToExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("empty.ly")
        try Data("\\version \"2.24.0\"\n\\markup { Only words }\n".utf8).write(to: source)
        let export = ScoreExport(format: .musicXML, lilypond: try #require(exportLilyPond), source: source,
                                 resources: Self.resources, folder: folder.appendingPathComponent("out"))
        let outcome: Result<ScoreExport.Output, ScoreExport.Failure> = await withCheckedContinuation { continuation in
            export.start { continuation.resume(returning: $0) }
        }
        guard case .failure(.noMusic) = outcome else {
            Issue.record("expected noMusic, got \(outcome)")
            return
        }
    }

    /// FMAC_EXPORT_FILE=<score.ly>: exports that file (with FMAC_DUMP_XML
    /// to keep the result) and reports the time it took.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FMAC_EXPORT_FILE"] != nil))
    func exportFile() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FMAC_EXPORT_FILE"]!)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let export = ScoreExport(format: .musicXML, lilypond: try #require(exportLilyPond), source: source,
                                 resources: Self.resources, folder: folder)
        let outcome: Result<ScoreExport.Output, ScoreExport.Failure> = await withCheckedContinuation { continuation in
            export.start { continuation.resume(returning: $0) }
        }
        let output = try outcome.get()
        print("exported \(output.files.map(\.lastPathComponent)) in \(Date().timeIntervalSince(start)) s")
        if let dump = ProcessInfo.processInfo.environment["FMAC_DUMP_XML"], dump.hasPrefix("/") {
            for file in output.files {
                try? FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: dump).appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    /// FMAC_EVENTS_FILE=<events.txt>: converts fmac-export.ly's records
    /// and reports the time it took.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FMAC_EVENTS_FILE"] != nil))
    func convertEvents() throws {
        let text = try String(contentsOfFile: ProcessInfo.processInfo.environment["FMAC_EVENTS_FILE"]!, encoding: .utf8)
        var start = Date()
        let events = ScoreEvents(parsing: text)
        print("parsed \(events.scores.first?.events.count ?? 0) events in \(Date().timeIntervalSince(start)) s")
        start = Date()
        let documents = MusicXMLWriter().documents(events)
        print("wrote \(documents.map(\.utf8.count)) bytes in \(Date().timeIntervalSince(start)) s")
        if let dump = ProcessInfo.processInfo.environment["FMAC_DUMP_XML"], dump.hasPrefix("/") {
            for (index, document) in documents.enumerated() {
                try Data(document.utf8).write(to: URL(fileURLWithPath: dump).appendingPathComponent("events-\(index + 1).musicxml"))
            }
        }
    }

    /// A project's own settings file still applies.
    @Test func keepsTheProjectsSettingsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ours = URL(fileURLWithPath: "/app/fmac-export.ly")
        #expect(try ScoreExport.arguments(adding: ours, to: ["-I", "x"], folder: folder)
                == ["-dinclude-settings=/app/fmac-export.ly", "-I", "x"])
        let both = try ScoreExport.arguments(adding: ours, to: ["-dinclude-settings=/p/my \"s\".ly", "-I", "x"], folder: folder)
        #expect(both == ["-dinclude-settings=" + folder.appendingPathComponent("fmac-settings.ly").path, "-I", "x"])
        let text = try String(contentsOf: folder.appendingPathComponent("fmac-settings.ly"), encoding: .utf8)
        #expect(text == "\\include \"/p/my \\\"s\\\".ly\"\n\\include \"/app/fmac-export.ly\"\n")
    }
}
