import Foundation

/// Creates a new multi-file LilyPond project laid out the way larger
/// projects are usually organized (and as LilyPond's Learning Manual
/// suggests): the music in one include file per instrument, shared settings
/// in a style sheet, the score and each part as small files that only put
/// things together.
///
///     <name>.ly              the full score: engrave this
///     style.ily              page format and layout, shared with the parts
///     music/global.ily       key, time signature, tempo
///     music/<part>.ily       the music, one file per instrument
///     parts/<part>.ly        one engravable part per instrument
///
/// Every .ily names the score as its master (`-*- master: ...;`), so
/// engraving any of them engraves the score.
public enum ProjectTemplate {
    public enum Ensemble: String, CaseIterable, Sendable, Identifiable {
        case piano, voiceAndPiano, choir, stringQuartet, chamberOrchestra
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .piano: "Piano"
            case .voiceAndPiano: "Voice and Piano"
            case .choir: "SATB Choir"
            case .stringQuartet: "String Quartet"
            case .chamberOrchestra: "Chamber Orchestra"
            }
        }

        var groups: [(name: String?, context: String, instruments: [Instrument])] {
            switch self {
            case .piano:
                [(nil, "", [.piano])]
            case .voiceAndPiano:
                [(nil, "", [.voice, .piano])]
            case .choir:
                [("Choir", "ChoirStaff", [.soprano, .alto, .tenor, .bass])]
            case .stringQuartet:
                [("Strings", "StaffGroup", [.violinI, .violinII, .viola, .cello])]
            case .chamberOrchestra:
                [("Woodwinds", "StaffGroup", [.flute, .oboe, .clarinet, .bassoon]),
                 ("Brass", "StaffGroup", [.horn, .trumpet]),
                 ("Percussion", "", [.timpani]),
                 ("Strings", "StaffGroup", [.violinI, .violinII, .viola, .cello, .doubleBass])]
            }
        }
    }

    struct Instrument {
        enum Kind { case single, piano, voice }
        var name: String
        var shortName: String
        /// The music variable.
        var variable: String
        /// File name without extension.
        var file: String
        var clef: String
        var relative: String
        var midi: String
        var kind: Kind = .single
        /// Written pitch for transposing instruments: `\transposition` value.
        var transposition: String?

        static let piano = Instrument(name: "Piano", shortName: "Pno.", variable: "piano", file: "piano",
                                      clef: "treble", relative: "c''", midi: "acoustic grand", kind: .piano)
        static let voice = Instrument(name: "Voice", shortName: "V.", variable: "melody", file: "voice",
                                      clef: "treble", relative: "c''", midi: "voice oohs", kind: .voice)
        static let soprano = Instrument(name: "Soprano", shortName: "S.", variable: "soprano", file: "soprano",
                                        clef: "treble", relative: "c''", midi: "choir aahs", kind: .voice)
        static let alto = Instrument(name: "Alto", shortName: "A.", variable: "alto", file: "alto",
                                     clef: "treble", relative: "c'", midi: "choir aahs", kind: .voice)
        static let tenor = Instrument(name: "Tenor", shortName: "T.", variable: "tenor", file: "tenor",
                                      clef: "treble_8", relative: "c'", midi: "choir aahs", kind: .voice)
        static let bass = Instrument(name: "Bass", shortName: "B.", variable: "bass", file: "bass",
                                     clef: "bass", relative: "c", midi: "choir aahs", kind: .voice)
        static let violinI = Instrument(name: "Violin I", shortName: "Vl. I", variable: "violinI", file: "violin-1",
                                        clef: "treble", relative: "c''", midi: "violin")
        static let violinII = Instrument(name: "Violin II", shortName: "Vl. II", variable: "violinII",
                                         file: "violin-2", clef: "treble", relative: "c''", midi: "violin")
        static let viola = Instrument(name: "Viola", shortName: "Va.", variable: "viola", file: "viola",
                                      clef: "alto", relative: "c'", midi: "viola")
        static let cello = Instrument(name: "Cello", shortName: "Vc.", variable: "cello", file: "cello",
                                      clef: "bass", relative: "c", midi: "cello")
        static let doubleBass = Instrument(name: "Double Bass", shortName: "Cb.", variable: "doubleBass",
                                           file: "double-bass", clef: "bass_8", relative: "c", midi: "contrabass")
        static let flute = Instrument(name: "Flute", shortName: "Fl.", variable: "flute", file: "flute",
                                      clef: "treble", relative: "c''", midi: "flute")
        static let oboe = Instrument(name: "Oboe", shortName: "Ob.", variable: "oboe", file: "oboe",
                                     clef: "treble", relative: "c''", midi: "oboe")
        static let clarinet = Instrument(name: "Clarinet in B♭", shortName: "Cl.", variable: "clarinet",
                                         file: "clarinet", clef: "treble", relative: "c''", midi: "clarinet",
                                         transposition: "bes")
        static let bassoon = Instrument(name: "Bassoon", shortName: "Bn.", variable: "bassoon", file: "bassoon",
                                        clef: "bass", relative: "c", midi: "bassoon")
        static let horn = Instrument(name: "Horn in F", shortName: "Hn.", variable: "horn", file: "horn",
                                     clef: "treble", relative: "c''", midi: "french horn",
                                     transposition: "f")
        static let trumpet = Instrument(name: "Trumpet in B♭", shortName: "Tpt.", variable: "trumpet",
                                        file: "trumpet", clef: "treble", relative: "c''", midi: "trumpet",
                                        transposition: "bes")
        static let timpani = Instrument(name: "Timpani", shortName: "Timp.", variable: "timpani", file: "timpani",
                                        clef: "bass", relative: "c", midi: "timpani")
    }

    /// "My Little Song" → "my-little-song".
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let parts = folded.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return parts.isEmpty ? "score" : parts.joined(separator: "-")
    }

    public static func mainFileName(title: String) -> String { slug(title) + ".ly" }

    /// The files to write, relative to the project folder.
    public static func files(title: String, ensemble: Ensemble, version: LilyPondVersion?,
                             paperSize: String = "a4") -> [(path: String, contents: String)] {
        let version = "\\version \"\(version?.description ?? "2.24.0")\""
        let main = mainFileName(title: title)
        let instruments = ensemble.groups.flatMap(\.instruments)
        let titleString = title.replacingOccurrences(of: "\"", with: "\\\"")
        var files: [(String, String)] = []

        // The score.
        var score = """
            \(version)

            % \(title)
            %
            % Project layout: engrave this file for the full score.
            %   \(main.padding(toLength: 22, withPad: " ", startingAt: 0))this file: puts the score together
            %   style.ily              page format and layout, shared with the parts
            %   music/global.ily       key, time signature, tempo
            %   music/<part>.ily       the music, one file per instrument
            """
        if instruments.count > 1 { score += "\n%   parts/<part>.ly        one part per instrument" }
        score += """

            % The .ily files name this file as their master, so engraving any of
            % them in Frescobaldi engraves the score.

            \\include "style.ily"
            \\include "music/global.ily"
            \(instruments.map { "\\include \"music/\($0.file).ily\"" }.joined(separator: "\n"))

            \\header {
              title = "\(titleString)"
              composer = ""
            }

            \\score {
              <<

            """
        for group in ensemble.groups {
            let staves = group.instruments.map { staff($0, indent: group.context.isEmpty ? 4 : 6) }.joined(separator: "\n")
            if group.context.isEmpty {
                score += staves + "\n"
            } else {
                score += "    \\new \(group.context) = \"\(group.name ?? group.context)\" <<\n\(staves)\n    >>\n"
            }
        }
        score += """
              >>
              \\layout { }
              \\midi { }
            }

            """
        files.append((main, score))

        files.append(("style.ily", """
            \(version)
            % -*- master: \(main);

            % Page format and layout, shared by the score and the parts.
            #(set-global-staff-size 18)

            \\paper {
              #(set-paper-size "\(paperSize)")
            }

            \\layout {
              % Settings for the score and every part, for example:
              % \\context { \\Staff \\RemoveEmptyStaves }
            }

            """))

        files.append(("music/global.ily", """
            \(version)
            % -*- master: ../\(main);

            % Shared by every instrument: key, time signature, tempo, rehearsal marks.
            global = {
              \\key c \\major
              \\time 4/4
              \\tempo "Moderato" 4 = 96
            }

            """))

        for instrument in instruments {
            files.append(("music/\(instrument.file).ily", music(instrument, version: version, main: main)))
        }

        if instruments.count > 1 {
            for instrument in instruments {
                files.append(("parts/\(instrument.file).ly", part(instrument, version: version, title: titleString)))
            }
        }
        return files
    }

    // MARK: Pieces

    private static func staff(_ instrument: Instrument, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let names = "instrumentName = \"\(instrument.name)\" shortInstrumentName = \"\(instrument.shortName)\""
        switch instrument.kind {
        case .piano:
            return """
                \(pad)\\new PianoStaff \\with { \(names) } <<
                \(pad)  \\new Staff = "right" \\with { midiInstrument = "\(instrument.midi)" } \\pianoRight
                \(pad)  \\new Staff = "left" \\with { midiInstrument = "\(instrument.midi)" } \\pianoLeft
                \(pad)>>
                """
        case .voice:
            return """
                \(pad)\\new Staff \\with { \(names) midiInstrument = "\(instrument.midi)" }
                \(pad)  \\new Voice = "\(instrument.variable)" \\\(instrument.variable)
                \(pad)\\new Lyrics \\lyricsto "\(instrument.variable)" \\\(instrument.variable)Words
                """
        case .single:
            return "\(pad)\\new Staff \\with { \(names) midiInstrument = \"\(instrument.midi)\" } \\\(instrument.variable)"
        }
    }

    private static func music(_ instrument: Instrument, version: String, main: String) -> String {
        var text = "\(version)\n% -*- master: ../\(main);\n\n"
        switch instrument.kind {
        case .piano:
            text += """
                pianoRight = \\relative c'' {
                  \\global
                  \\clef treble
                  R1*4 |
                }

                pianoLeft = \\relative c {
                  \\global
                  \\clef bass
                  R1*4 |
                }

                """
        case .voice:
            text += """
                \(instrument.variable) = \\relative \(instrument.relative) {
                  \\global
                  \\clef "\(instrument.clef)"
                  R1*4 |
                }

                \(instrument.variable)Words = \\lyricmode {

                }

                """
        case .single:
            if let transposition = instrument.transposition {
                text += """
                    % \(instrument.name), at written pitch (as the player reads it):
                    % \\transposition makes the MIDI sound right, and the key
                    % signature is transposed from the concert key in \\global.
                    \(instrument.variable) = \\relative \(instrument.relative) {
                      \\transposition \(transposition)
                      \\transpose \(transposition) c' \\global
                      \\clef "\(instrument.clef)"
                      R1*4 |
                    }

                    """
            } else {
                text += """
                    \(instrument.variable) = \\relative \(instrument.relative) {
                      \\global
                      \\clef "\(instrument.clef)"
                      R1*4 |
                    }

                    """
            }
        }
        return text
    }

    private static func part(_ instrument: Instrument, version: String, title: String) -> String {
        var text = """
            \(version)

            % The \(instrument.name) part. The music is in ../music/\(instrument.file).ily.
            \\include "../style.ily"
            \\include "../music/global.ily"
            \\include "../music/\(instrument.file).ily"

            \\header {
              title = "\(title)"
              instrument = "\(instrument.name)"
            }

            \\score {

            """
        switch instrument.kind {
        case .piano:
            text += """
                  \\new PianoStaff <<
                    \\new Staff = "right" \\pianoRight
                    \\new Staff = "left" \\pianoLeft
                  >>

                """
        case .voice:
            text += """
                  <<
                    \\new Staff \\new Voice = "\(instrument.variable)" \\\(instrument.variable)
                    \\new Lyrics \\lyricsto "\(instrument.variable)" \\\(instrument.variable)Words
                  >>

                """
        case .single:
            text += "  \\new Staff \\with { midiInstrument = \"\(instrument.midi)\" } \\compressMMRests \\\(instrument.variable)\n"
        }
        text += """
              \\layout { }
            }

            """
        return text
    }
}
