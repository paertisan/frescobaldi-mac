import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct PitchTests {
    @Test func parsesAndNames() throws {
        let bes = try #require(Pitch("bes,"))
        #expect(bes == Pitch(6, -1, octave: -1))
        #expect(bes.semitones == -14)
        #expect(Pitch("ees'") == Pitch(2, -1, octave: 1))
        #expect(Pitch("fisis''")?.alteration == 2)
        #expect(Pitch("x") == nil && Pitch("cx") == nil)
        #expect(bes.name(in: .nederlands) == "bes,")
        #expect(Pitch("ees")!.name(in: .nederlands) == "ees")
        #expect(Pitch("ees")!.name(in: .english) == "ef")
        #expect(Pitch("ees")!.name(in: .deutsch) == "es")
        #expect(Pitch("aes")!.name(in: .deutsch) == "as")
        #expect(Pitch("bes")!.name(in: .deutsch) == "b")
        #expect(Pitch("b")!.name(in: .deutsch) == "h")
        #expect(Pitch("beses")!.name(in: .deutsch) == "heses")
        #expect(Pitch("cis''")!.name(in: .italiano) == "dod''")
        #expect(Pitch("des")!.name(in: .français) == "réb")
        #expect(Pitch("fis")!.name(in: .español) == "fas")
        #expect(Pitch("aes")!.displayName == "A♭")
    }

    @Test func lineOfFifths() {
        #expect(Pitch("bes")!.fifths == -2 && Pitch("fis")!.fifths == 6)
        #expect(Pitch.at(fifths: 10, near: Pitch("bes")!) == Pitch("ais"))
        #expect(Pitch.at(fifths: -9, near: Pitch("a")!) == Pitch("beses"))
        #expect(Pitch.at(fifths: 12, near: Pitch(0, octave: 1)) == Pitch("bis"))
    }

    @Test func keys() {
        let major = KeySignature.keys(.major)
        #expect(major.count == 15 && major.first?.title == "C♭ major" && major.last?.title == "C♯ major")
        #expect(KeySignature.keys(.minor)[7].title == "A minor")
        #expect(KeySignature.keys(.dorian)[7].title == "D dorian")
        #expect(KeySignature(tonic: Pitch("ees")!, mode: .major).fifths == -3)
    }

    @Test func barDurations() {
        #expect(TimeSignature(4, 4).barDuration == "1")
        #expect(TimeSignature(3, 4).barDuration == "2.")
        #expect(TimeSignature(6, 8).barDuration == "2.")
        #expect(TimeSignature(12, 8).barDuration == "1.")
        #expect(TimeSignature(2, 4).barDuration == "2")
        #expect(TimeSignature(4, 2).barDuration == "\\breve")
        #expect(TimeSignature(5, 4).barDuration == "4*5")
        #expect(TimeSignature(7, 8).barDuration == "8*7")
        #expect(TimeSignature(6, 8).beat == "4." && TimeSignature(3, 4).beat == "4" && TimeSignature(2, 2).beat == "2")
        #expect(TimeSignature(4, 4).title == "C (4/4)" && TimeSignature(4, 4, symbol: false).title == "4/4")
        #expect(TimeSignature(3, 8).fits(pickup: "8") && TimeSignature(3, 8).fits(pickup: "8."))
        #expect(!TimeSignature(3, 8).fits(pickup: "4.") && !TimeSignature(2, 4).fits(pickup: "2"))
        #expect(TimeSignature(4, 4).fits(pickup: "2.") && !TimeSignature(3, 4).fits(pickup: "2."))
    }
}

@Suite(.timeLimit(.minutes(5))) struct ProjectTemplateTests {
    @Test func slugs() {
        #expect(ProjectTemplate.slug("My Little Song") == "my-little-song")
        #expect(ProjectTemplate.slug("Für Élise, Op. 59!") == "fur-elise-op-59")
        #expect(ProjectTemplate.slug("???") == "score")
    }

    @Test func playersAreNumbered() {
        var spec = ScoreSpec(ensemble: Ensemble.named("concert-band")!)
        spec.players.append(Player(instrument: "violin", name: "Solo Violin"))
        let players = spec.resolvedPlayers
        let clarinets = players.filter { $0.instrument.id == "clarinet" }
        #expect(clarinets.map(\.name) == ["Clarinet 1 in B♭", "Clarinet 2 in B♭", "Clarinet 3 in B♭"])
        #expect(clarinets.map(\.shortName) == ["Cl. 1", "Cl. 2", "Cl. 3"])
        #expect(clarinets.map(\.variable) == ["clarinetI", "clarinetII", "clarinetIII"])
        #expect(clarinets.map(\.file) == ["clarinet-1", "clarinet-2", "clarinet-3"])
        #expect(players.first { $0.instrument.id == "oboe" }?.name == "Oboe")
        #expect(players.last?.name == "Solo Violin" && players.last?.variable == "violin")

        let quartet = ScoreSpec(ensemble: Ensemble.named("string-quartet")!).resolvedPlayers
        #expect(quartet.map(\.name) == ["Violin I", "Violin II", "Viola", "Cello"])

        // Two kinds of guitar don't share a variable.
        var guitars = ScoreSpec()
        guitars.players = [Player(instrument: "guitar"), Player(instrument: "guitar-tab")]
        #expect(Set(guitars.resolvedPlayers.map(\.variable)).count == 2)
        // Variables are unique in every preset.
        for ensemble in Ensemble.all {
            let variables = ScoreSpec(ensemble: ensemble).resolvedPlayers.map(\.variable)
            #expect(Set(variables).count == variables.count, "\(ensemble.id)")
        }
        #expect(Ensemble.all.allSatisfy { $0.instruments.allSatisfy { Instrument.named($0) != nil } })
        #expect(Set(Instrument.all.map(\.id)).count == Instrument.all.count)
    }

    @Test func newPlayersGoInScoreOrder() {
        var spec = ScoreSpec(ensemble: Ensemble.named("violin-piano")!)
        #expect(spec.insertionIndex(for: Instrument.named("cello")!) == 1)
        #expect(spec.insertionIndex(for: Instrument.named("flute")!) == 0)
        #expect(spec.insertionIndex(for: Instrument.named("chord-names")!) == 0)
        spec = ScoreSpec(ensemble: Ensemble.named("lead-sheet")!)
        #expect(spec.insertionIndex(for: Instrument.named("piano")!) == 1, "before the voice, after the chords")
        #expect(spec.insertionIndex(for: Instrument.named("violin")!) == 2)
    }

    @Test func writesAFolder() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("write-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("My Quartet")
        let main = try ProjectTemplate.write(ScoreSpec(ensemble: Ensemble.named("string-quartet")!), to: folder,
                                             version: LilyPondVersion(2, 26, 0))
        #expect(main.lastPathComponent == "my-quartet.ly")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("parts/viola.ly").path))
        #expect(throws: (any Error).self) {
            try ProjectTemplate.write(ScoreSpec(ensemble: Ensemble.named("piano")!), to: folder, version: nil)
        }
    }

    private func files(_ spec: ScoreSpec, name: String = "Test Piece") -> [String: String] {
        Dictionary(uniqueKeysWithValues: ProjectTemplate.files(for: spec, name: name, version: LilyPondVersion(2, 26, 0))
            .map { ($0.path, $0.contents) })
    }

    @Test func layoutAndMasters() throws {
        var spec = ScoreSpec(ensemble: Ensemble.named("chamber-orchestra")!)
        spec.paperSize = "letter"
        spec.title = "Overture"
        spec.composer = "A. \"Quoted\" Name"
        let list = ProjectTemplate.files(for: spec, name: "Test Piece", version: LilyPondVersion(2, 26, 0))
        let paths = list.map(\.path)
        #expect(paths.prefix(4) == ["test-piece.ly", "header.ily", "style.ily", "music/global.ily"])
        #expect(paths.contains("music/clarinet.ily") && paths.contains("parts/clarinet.ly"))
        #expect(paths.contains("music/violin-2.ily") && paths.contains("parts/violin-2.ly"))
        let byPath = files(spec)
        #expect(byPath["style.ily"]?.contains("#(set-paper-size \"letter\")") == true)
        #expect(byPath["header.ily"]?.contains("title = \"Overture\"") == true)
        #expect(byPath["header.ily"]?.contains("composer = \"A. \\\"Quoted\\\" Name\"") == true)
        #expect(byPath["header.ily"]?.contains("tagline = ##f") == true)
        for (path, text) in list {
            #expect(text.hasPrefix("\\version \"2.26.0\""), "\(path)")
            if path.hasSuffix(".ily") {
                let file = URL(fileURLWithPath: "/p/\(path)")
                #expect(DocumentVariables.master(for: file, text: text)?.path == "/p/test-piece.ly", "\(path)")
            }
        }
        // Concert pitch: the music has no \transposition, the staff transposes.
        #expect(byPath["music/clarinet.ily"]?.contains("\\transposition") == false)
        #expect(byPath["test-piece.ly"]?.contains("{ \\transposition bes \\transpose bes c' << \\global \\clarinet >> }") == true)
        #expect(byPath["parts/clarinet.ly"]?.contains("\\transpose bes c'") == true)
        #expect(byPath["parts/clarinet.ly"]?.contains("instrument = \\markup \\concat { \"Clarinet in B\" \\hspace #0.2 \\fontsize #-2 \\raise #0.5 \\flat }") == true)
        // Octave transpositions are entered as written.
        #expect(byPath["music/double-bass.ily"]?.contains("\\transposition c\n") == true)
        #expect(byPath["test-piece.ly"]?.contains("\\RemoveEmptyStaves") == true)

        let solo = ProjectTemplate.files(for: ScoreSpec(ensemble: Ensemble.named("piano")!), name: "Solo", version: nil)
        #expect(solo.map(\.path) == ["solo.ly", "header.ily", "style.ily", "music/global.ily", "music/piano.ily"],
                "no parts for one player")
        #expect(solo[0].contents.hasPrefix("\\version \"2.24.0\""))
    }

    @Test func musicOptions() {
        var spec = ScoreSpec(ensemble: Ensemble.named("clarinet-piano")!)
        spec.key = KeySignature(tonic: Pitch("b")!, mode: .major)
        spec.time = TimeSignature(6, 8)
        spec.pickup = "8"
        spec.bars = 8
        spec.tempo = Tempo(text: "Allegro", beat: "4.", bpm: 112)
        spec.language = .english
        spec.entry = .fixed
        var byPath = files(spec)
        let global = byPath["music/global.ily"] ?? ""
        #expect(global.contains("\\language \"english\""))
        #expect(global.contains("\\key b \\major\n  \\time 6/8\n  \\tempo \"Allegro\" 4. = 112\n  \\partial 8 s8 |\n  s2.*8 |"))
        #expect(byPath["music/clarinet.ily"]?.contains("clarinet = \\fixed c'' {\n  \\clef treble\n  r8 |\n  R2.*8 |\n}") == true)
        // B major for a B♭ clarinet reads D♭ major, not C♯ major.
        #expect(byPath["test-piece.ly"]?.contains("\\transposition bf \\transpose as c'") == true)
        #expect(byPath["header.ily"]?.contains("\\language") == false)

        // Written pitch: \transposition in the music, the key transposed on the staff.
        spec.concertPitch = false
        spec.key = KeySignature(tonic: Pitch("ees")!, mode: .major)
        spec.language = .nederlands
        spec.time = TimeSignature(4, 4, symbol: false)
        byPath = files(spec)
        #expect(byPath["music/clarinet.ily"]?.contains("  \\transposition bes\n  \\clef treble\n") == true)
        #expect(byPath["test-piece.ly"]?.contains("<< \\transpose bes c' \\global \\clarinet >>") == true)
        #expect(byPath["music/global.ily"]?.contains("\\numericTimeSignature\n  \\time 4/4") == true)

        // A score in C: as it sounds, but tenor saxophones keep their octave.
        spec = ScoreSpec(ensemble: Ensemble.named("saxophone-quartet")!)
        spec.transposedScore = false
        byPath = files(spec)
        let score = byPath["test-piece.ly"] ?? ""
        #expect(score.contains("} << \\global \\altoSax >>"))
        #expect(score.contains("{ \\transposition c \\transpose c c' << \\global \\tenorSax >> }"))
        #expect(byPath["parts/alto-sax.ly"]?.contains("\\transpose ees c'") == true)
    }

    /// Settings to engrave: every preset, plus combinations of the options.
    static let cases: [(String, ScoreSpec)] = {
        var cases = Ensemble.all.map { ($0.id, ScoreSpec(ensemble: $0)) }
        var spec = ScoreSpec(ensemble: Ensemble.named("orchestra")!)
        spec.key = KeySignature(tonic: Pitch("fis")!, mode: .minor)
        spec.time = TimeSignature(5, 4)
        spec.pickup = "4"
        spec.tempo = Tempo(text: "Largo", beat: "4", bpm: 50)
        spec.transposedScore = false
        spec.language = .deutsch
        spec.landscape = true
        spec.paperSize = "a3"
        cases.append(("orchestra in C, F♯ minor, 5/4, German", spec))
        spec = ScoreSpec(ensemble: Ensemble.named("concert-band")!)
        spec.concertPitch = false
        spec.key = KeySignature(tonic: Pitch("des")!, mode: .major)
        spec.time = TimeSignature(7, 8)
        spec.entry = .absolute
        spec.language = .italiano
        spec.instrumentNames = .full
        cases.append(("band as written, D♭ major, 7/8, Italian", spec))
        spec = ScoreSpec(ensemble: Ensemble.named("satb-organ")!)
        spec.language = .français
        spec.time = TimeSignature(3, 2)
        spec.title = "Motet"
        spec.subtitle = "for Easter"
        spec.poet = "Anon."
        spec.copyright = "© 2026"
        spec.tagline = true
        spec.midi = false
        cases.append(("choir and organ, French, 3/2, no MIDI", spec))
        spec = ScoreSpec(ensemble: Ensemble.named("lead-sheet")!)
        spec.language = .español
        spec.pickup = "8"
        cases.append(("lead sheet, Spanish, pickup", spec))
        spec = ScoreSpec()
        spec.players = ["piano", "organ", "guitar-tab", "guitar-tab", "drum-set", "marimba", "celesta"]
            .map { Player(instrument: $0) }
        spec.grouping = .together
        spec.language = .english
        spec.key = KeySignature(tonic: Pitch("cis")!, mode: .major)
        cases.append(("keyboards and guitars together, C♯ major, English", spec))
        spec = ScoreSpec(ensemble: Ensemble.named("clarinet-piano")!)
        spec.key = KeySignature(tonic: Pitch("b")!, mode: .major)
        spec.language = .english
        cases.append(("clarinet in concert B major, English", spec))
        spec = ScoreSpec()
        spec.players = Instrument.all.map { Player(instrument: $0.id) }
        spec.paperSize = "tabloid"
        cases.append(("every instrument", spec))
        return cases
    }()

    private func write(_ spec: ScoreSpec) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTemplate-\(UUID().uuidString.prefix(8))/Test Piece")
        for (path, contents) in ProjectTemplate.files(for: spec, name: "Test Piece", version: LilyPondVersion(2, 26, 0)) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    /// Every generated project is tidy by the project navigator's standards.
    @Test(arguments: cases.map(\.0))
    func noSuggestions(_ name: String) throws {
        let spec = try #require(Self.cases.first { $0.0 == name }?.1)
        let root = try write(spec)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let project = LilyPondProject.load(main: root.appendingPathComponent("test-piece.ly"))
        #expect(project.problems.isEmpty, "\(project.problems.map(\.message))")
    }

    /// Engraves each generated score and its parts with the real LilyPond, if
    /// installed: no errors and no warnings.
    @Test(.enabled(if: LilyPondLocator.locate() != nil, "LilyPond not installed"),
          arguments: cases.map(\.0))
    func engraves(_ name: String) async throws {
        let spec = try #require(Self.cases.first { $0.0 == name }?.1)
        let lilypond = try #require(LilyPondLocator.locate())
        let root = try write(spec)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var sources = [root.appendingPathComponent("test-piece.ly")]
        let parts = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("parts").path)) ?? []
        sources += parts.sorted().map { root.appendingPathComponent("parts/\($0)") }
        #expect(parts.isEmpty == !spec.hasParts)
        try await withThrowingTaskGroup(of: (String, EngraveJob.Result).self) { group in
            for source in sources {
                group.addTask {
                    let job = EngraveJob(lilypond: lilypond, source: source)
                    let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
                        do {
                            try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    return (source.lastPathComponent, result)
                }
            }
            for try await (file, result) in group {
                #expect(result.succeeded, "\(name), \(file): \(result.log.suffix(1200))")
                // Too many instruments for one page or the MIDI channels.
                let messages = name == "every instrument" ? result.messages.filter(\.severity.isError) : result.messages
                #expect(messages.isEmpty, "\(name), \(file): \(messages.map { "\($0.line): \($0.message)" })")
                #expect(!result.pdfs.isEmpty, "\(name), \(file)")
                #expect(result.midis.isEmpty == (!spec.midi || file != "test-piece.ly"), "\(name), \(file)")
            }
        }
    }

    /// FMAC_DUMP=<folder> writes every case there, to look at.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FMAC_DUMP"] != nil))
    func dump() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FMAC_DUMP"]!)
        for (name, spec) in Self.cases {
            for (path, contents) in ProjectTemplate.files(for: spec, name: "Test Piece", version: LilyPondVersion(2, 26, 0)) {
                let url = folder.appendingPathComponent(ProjectTemplate.slug(name)).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            }
        }
    }
}
