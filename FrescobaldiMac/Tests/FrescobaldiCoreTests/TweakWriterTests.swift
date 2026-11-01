import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct GrobLinkTests {
    // As fmac-edit.ly writes it (LilyPond 2.26).
    static let dynamic = "fmac://grob?name=DynamicText&ev=absolute-dynamic-event&line=4&char=18&label=mf&u=1.7573"
        + "&ss=1.7573&x=0.0000,1.4682&y=-0.5840,1.1680&eo=0,0&xo=-0.0820&t=DynamicLineSpanner&tl=4%2C20"
        + "&yo=-3.2181&pad=0.6000&spad=0.1000&ospad=&dir=-1&cp=&pos=&piece=1%2C1&file=%2FUsers%2Frwr%2FMy%20Scores%2Fa.ly"

    @Test func parsesLink() throws {
        let link = try #require(GrobLink(string: Self.dynamic))
        #expect(link.grob == "DynamicText" && link.event == "absolute-dynamic-event")
        #expect(link.path == "/Users/rwr/My Scores/a.ly")
        #expect(link.line == 4 && link.column == 18 && link.label == "mf")
        #expect(link.xExtent == GrobLink.Point(0, 1.4682) && link.yExtent == GrobLink.Point(-0.584, 1.168))
        #expect(link.extraOffset == .zero && link.xOffset == -0.082)
        #expect(link.target == "DynamicLineSpanner" && link.targetLine == 4 && link.targetColumn == 20)
        #expect(link.yOffset == -3.2181 && link.padding == 0.6 && link.staffPadding == 0.1)
        #expect(link.outsideStaffPadding == nil && link.direction == -1)
        #expect(link.controlPoints.isEmpty && link.positions == nil && link.piece == 1 && link.pieces == 1)
        #expect(link.summary == "Dynamic · mf · line 4")
        #expect(abs(link.pointsPerStaffSpace - 4.9813) < 0.001)
    }

    @Test func parsesCurvesBeamsAndPieces() throws {
        let slur = try #require(GrobLink(string: "fmac://grob?name=Slur&ev=slur-event&line=7&char=29&u=1.7573&ss=1.7573"
            + "&x=0.6436,7.5746&y=-7.6657,-6.0050&cp=0.6836,-6.5450;2.1922,-7.6257;6.1988,-7.3333;7.5346,-6.0450"
            + "&piece=2%2C2&file=/tmp/a&b=c.ly"))
        #expect(slur.controlPoints.count == 4 && slur.controlPoints[1] == GrobLink.Point(2.1922, -7.6257))
        #expect(slur.piece == 2 && slur.pieces == 2)
        #expect(slur.path == "/tmp/a&b=c.ly", "an unencoded file name is the rest of the query")
        #expect(slur.properties == [.extraOffset] && slur.summary == "Slur · line 7")
        let handle = slur.handles[0]
        #expect(abs(handle.x - (0.6836 - 0.6436) * slur.pointsPerUnit) < 1e-9)
        #expect(abs(handle.y - (-6.5450 + 7.6657) * slur.pointsPerUnit) < 1e-9)

        let beam = try #require(GrobLink(string: "fmac://grob?name=Beam&ev=note-event&line=9&char=4&u=1.7573"
            + "&ss=1.7573&x=-0.065,3.9776&y=-0.24,2.24&pos=0,2&file=/tmp/b.ly"))
        #expect(beam.positions == GrobLink.Point(0, 2) && beam.properties.isEmpty)
        #expect(beam.handles.count == 2)
        #expect(abs(beam.handles[1].y - 2.24 * beam.pointsPerUnit) < 1e-9)
    }

    @Test func rejectsOtherLinks() {
        #expect(GrobLink(string: "textedit:///tmp/x.ly:1:2:3") == nil)
        #expect(GrobLink(string: "fmac://grob?name=Script&line=0&char=1&file=/x.ly") == nil)
        #expect(GrobLink(string: "fmac://grob?name=Script&line=1&char=1") == nil)
    }

    @Test func dragsBecomeTweaks() throws {
        let link = try #require(GrobLink(string: Self.dynamic))
        let ss = link.pointsPerStaffSpace
        // Offset: staff spaces, rounded to 0.01; tiny components dropped.
        #expect(link.tweak(.extraOffset, movedBy: .init(ss * 1.234, ss * 0.03))
                == .set(property: "extra-offset", grob: nil, value: .pair(1.23, 0)))
        #expect(link.tweak(.extraOffset, movedBy: .init(ss * 0.04, -ss * 0.04)) == nil)
        #expect(link.tweak(.xOffset, movedBy: .init(ss, 0)) == .set(property: "X-offset", grob: nil, value: .number(0.92)))
        // Collision properties go to the dynamic's spanner. Below the staff,
        // moving down is more padding.
        #expect(link.tweak(.staffPadding, movedBy: .init(0, -ss * 2))
                == .set(property: "staff-padding", grob: "DynamicLineSpanner", value: .number(2.1)))
        #expect(link.tweak(.padding, movedBy: .init(0, ss * 0.5))
                == .set(property: "padding", grob: "DynamicLineSpanner", value: .number(0.1)))
        #expect(link.tweak(.yOffset, movedBy: .init(0, ss))
                == .set(property: "Y-offset", grob: "DynamicLineSpanner", value: .number(-2.22)))
        // Unset outside-staff-padding starts from LilyPond's 0.46.
        #expect(link.tweak(.outsideStaffPadding, movedBy: .init(0, -ss))
                == .set(property: "outside-staff-padding", grob: "DynamicLineSpanner", value: .number(1.46)))
        #expect(link.tweak(.padding, movedBy: .init(ss * 3, 0)) == nil, "only vertical moves change padding")

        var above = link
        above.direction = 1
        above.target = nil
        #expect(above.tweak(.padding, movedBy: .init(0, ss)) == .set(property: "padding", grob: nil, value: .number(1.6)))
        var unknown = link
        unknown.staffPadding = nil
        #expect(unknown.tweak(.staffPadding, movedBy: .init(0, ss)) == nil)
        #expect(!unknown.properties.contains(.staffPadding))
    }

    @Test func shapesAndBeamOffsets() throws {
        let slur = GrobLink(grob: "Slur", path: "/x.ly", line: 1, column: 0, unit: 1.7573, staffSpace: 3.5146)
        let ss = slur.pointsPerStaffSpace, u = slur.pointsPerUnit
        // x in LilyPond units, y in staff spaces (\shape scales y).
        #expect(slur.shape(movingPoint: 1, by: .init(u, ss))
                == .shape(offsets: [.zero, .init(1, 1), .zero, .zero], piece: 1, pieces: 1))
        #expect(slur.shape(movingPoint: nil, by: .init(0, -ss / 2))
                == .shape(offsets: Array(repeating: .init(0, -0.5), count: 4), piece: 1, pieces: 1))
        #expect(slur.shape(movingPoint: 0, by: .init(0.01, 0.01)) == nil)
        var broken = slur
        broken.pieces = 2
        broken.piece = 2
        // Lists of lists aren't scaled: y in LilyPond units too.
        #expect(broken.shape(movingPoint: 3, by: .init(0, ss))
                == .shape(offsets: [.zero, .zero, .zero, .init(0, 2)], piece: 2, pieces: 2))

        let beam = GrobLink(grob: "Beam", path: "/x.ly", line: 1, column: 0)
        let pt = beam.pointsPerStaffSpace
        #expect(beam.beamOffset(left: pt, right: -pt * 0.5) == .offset(property: "positions", value: .pair(1, -0.5)))
        #expect(beam.beamOffset(left: 0.1, right: 0.1) == nil)
        #expect(slur.beamOffset(left: pt, right: pt) == nil)
    }
}

@Suite struct TweakWriterTests {
    func link(_ grob: String, _ event: String, line: Int = 1, column: Int, target: String? = nil,
              targetColumn: Int? = nil, piece: Int = 1, pieces: Int = 1) -> GrobLink {
        GrobLink(grob: grob, event: event, path: "/x.ly", line: line, column: column, target: target,
                 targetLine: targetColumn == nil ? nil : line, targetColumn: targetColumn, piece: piece, pieces: pieces)
    }

    func column(of needle: String, in text: String) -> Int {
        let range = (text as NSString).range(of: needle)
        return TextEditLink.position(of: range.location, in: text as NSString).column
    }

    let offset = Tweak.set(property: "extra-offset", grob: nil, value: .pair(1, -0.5))

    @Test func insertsBeforePostEvents() throws {
        let text = "{ c4-> d^. e\\p f-1 }"
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", column: 4), to: text)
                == "{ c4-\\tweak extra-offset #'(1 . -0.5) -> d^. e\\p f-1 }")
        // Before the direction: \tweak can't come between ^ and `.`.
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", column: column(of: "^.", in: text)), to: text)
                == "{ c4-> d-\\tweak extra-offset #'(1 . -0.5) ^. e\\p f-1 }")
        #expect(try TweakWriter.apply(offset, for: link("DynamicText", "absolute-dynamic-event", column: column(of: "\\p", in: text)), to: text)
                == "{ c4-> d^. e-\\tweak extra-offset #'(1 . -0.5) \\p f-1 }")
        #expect(try TweakWriter.apply(.set(property: "padding", grob: nil, value: .number(1.25)),
                                      for: link("Fingering", "fingering-event", column: column(of: "-1", in: text)), to: text)
                == "{ c4-> d^. e\\p f-\\tweak padding #1.25 -1 }")
        // Markup with an explicit direction, and fingering inside a chord.
        let markup = "c4^\\markup { dolce } <c-1 e>4"
        #expect(try TweakWriter.apply(offset, for: link("TextScript", "text-script-event", column: 2), to: markup)
                == "c4-\\tweak extra-offset #'(1 . -0.5) ^\\markup { dolce } <c-1 e>4")
        #expect(try TweakWriter.apply(offset, for: link("Fingering", "fingering-event", column: 23), to: markup)
                == "c4^\\markup { dolce } <c-\\tweak extra-offset #'(1 . -0.5) -1 e>4")
    }

    @Test func updatesAnExistingTweak() throws {
        let text = "c4-\\tweak extra-offset #'(1 . 2) -> d"
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", column: 2), to: text)
                == "c4-\\tweak extra-offset #'(1 . -0.5) -> d")
        // Another property: a second tweak, the old one kept.
        #expect(try TweakWriter.apply(.set(property: "padding", grob: nil, value: .number(2)),
                                      for: link("Script", "articulation-event", column: 2), to: text)
                == "c4-\\tweak padding #2 -\\tweak extra-offset #'(1 . 2) -> d")
        // Further down a chain, with the old #' syntax and a direction.
        let chain = "c4^\\tweak color #red -\\tweak #'extra-offset #'(0 . 1) -."
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", column: 2), to: chain)
                == "c4^\\tweak color #red -\\tweak #'extra-offset #'(1 . -0.5) -.")
        // The same property for another grob doesn't count.
        let other = "c4-\\tweak Accidental.extra-offset #'(0 . 1) ->"
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", column: 2), to: other)
                == "c4-\\tweak extra-offset #'(1 . -0.5) -\\tweak Accidental.extra-offset #'(0 . 1) ->")
        // A tweak without a direction, before a dynamic.
        let plain = "e4\\tweak extra-offset #'(1 . 1) \\p"
        #expect(try TweakWriter.apply(offset, for: link("DynamicText", "absolute-dynamic-event", column: 2), to: plain)
                == "e4\\tweak extra-offset #'(1 . -0.5) \\p")
    }

    @Test func spannerPropertiesGoToTheEventThatMadeTheSpanner() throws {
        // The DynamicLineSpanner of \p\< comes from the hairpin.
        let text = "c4\\p\\< d e f\\!"
        let dynamic = link("DynamicText", "absolute-dynamic-event", column: 2, target: "DynamicLineSpanner", targetColumn: 4)
        let padding = Tweak.set(property: "staff-padding", grob: "DynamicLineSpanner", value: .number(3))
        let once = try TweakWriter.apply(padding, for: dynamic, to: text)
        #expect(once == "c4\\p-\\tweak DynamicLineSpanner.staff-padding #3 \\< d e f\\!")
        // Its own offset stays on the dynamic.
        #expect(try TweakWriter.apply(offset, for: dynamic, to: text) == "c4-\\tweak extra-offset #'(1 . -0.5) \\p\\< d e f\\!")
        // Again: the tweak is now at the spanner event's location.
        let twice = try TweakWriter.apply(.set(property: "staff-padding", grob: "DynamicLineSpanner", value: .number(4.5)),
                                          for: dynamic, to: once)
        #expect(twice == "c4\\p-\\tweak DynamicLineSpanner.staff-padding #4.5 \\< d e f\\!")
        // No spanner event known: the prefix on the object's own event.
        let pedal = link("SustainPedal", "sustain-event", column: 2, target: "SustainPedalLineSpanner")
        #expect(try TweakWriter.apply(.set(property: "padding", grob: "SustainPedalLineSpanner", value: .number(1)),
                                      for: pedal, to: "c4\\sustainOn d\\sustainOff")
                == "c4-\\tweak SustainPedalLineSpanner.padding #1 \\sustainOn d\\sustainOff")
    }

    @Test func shapesSlursAndTies() throws {
        let text = "c8( d) e~ e"
        let shape = Tweak.shape(offsets: [.zero, .init(0, 1), .init(0.5, 1), .zero], piece: 1, pieces: 1)
        let slur = link("Slur", "slur-event", column: 2)
        let once = try TweakWriter.apply(shape, for: slur, to: text)
        #expect(once == "c8-\\shape #'((0 . 0) (0 . 1) (0.5 . 1) (0 . 0)) ( d) e~ e")
        // A second drag adds to the offsets already there.
        let twice = try TweakWriter.apply(.shape(offsets: [.init(-1, 0), .zero, .zero, .init(0, 0.25)], piece: 1, pieces: 1),
                                          for: slur, to: once)
        #expect(twice == "c8-\\shape #'((-1 . 0) (0 . 1) (0.5 . 1) (0 . 0.25)) ( d) e~ e")
        #expect(try TweakWriter.apply(shape, for: link("Tie", "tie-event", column: column(of: "~", in: text)), to: text)
                == "c8( d) e-\\shape #'((0 . 0) (0 . 1) (0.5 . 1) (0 . 0)) ~ e")
        // The second piece of a broken slur; the first is left alone.
        let broken = link("Slur", "slur-event", column: 2, piece: 2, pieces: 2)
        let secondPiece = Tweak.shape(offsets: [.zero, .init(0, 1), .init(0.5, 1), .zero], piece: 2, pieces: 2)
        let second = try TweakWriter.apply(secondPiece, for: broken, to: text)
        #expect(second == "c8-\\shape #'(() ((0 . 0) (0 . 1) (0.5 . 1) (0 . 0))) ( d) e~ e")
        // A single list there means the first piece.
        let first = try TweakWriter.apply(secondPiece, for: broken, to: once)
        #expect(first == "c8-\\shape #'(((0 . 0) (0 . 1) (0.5 . 1) (0 . 0)) ((0 . 0) (0 . 1) (0.5 . 1) (0 . 0))) ( d) e~ e")
        #expect(throws: TweakWriter.Failure.unreadableValue("#(list 1 2)")) {
            try TweakWriter.apply(shape, for: slur, to: "c8-\\shape #(list 1 2) ( d)")
        }
    }

    @Test func offsetsBeamPositions() throws {
        let tweak = Tweak.offset(property: "positions", value: .pair(1, 0.5))
        let beam = link("Beam", "beam-event", column: 2)
        let once = try TweakWriter.apply(tweak, for: beam, to: "c8[ d e f]")
        #expect(once == "c8-\\offset positions #'(1 . 0.5) [ d e f]")
        #expect(try TweakWriter.apply(tweak, for: beam, to: once) == "c8-\\offset positions #'(2 . 1) [ d e f]")
    }

    @Test func overridesBeforeTheNoteWithoutEventSyntax() throws {
        // An automatic beam's link points at its first note.
        let tweak = Tweak.offset(property: "positions", value: .pair(0.5, 1))
        let text = "  g4 c8 d e f"
        let beam = link("Beam", "note-event", column: column(of: "c8", in: text))
        let once = try TweakWriter.apply(tweak, for: beam, to: text)
        #expect(once == "  g4 \\once \\offset positions #'(0.5 . 1) Beam c8 d e f")
        let again = link("Beam", "note-event", column: column(of: "c8", in: once))
        #expect(try TweakWriter.apply(tweak, for: again, to: once) == "  g4 \\once \\offset positions #'(1 . 2) Beam c8 d e f")
        // A note in a chord: before the chord.
        let chord = "<c e g>8 d e f"
        #expect(try TweakWriter.apply(tweak, for: link("Beam", "note-event", column: 1), to: chord)
                == "\\once \\offset positions #'(0.5 . 1) Beam <c e g>8 d e f")
        // A value: \once \override, updated the next time.
        let color = Tweak.set(property: "extra-offset", grob: nil, value: .pair(0, 1))
        let overridden = try TweakWriter.apply(color, for: link("Beam", "note-event", column: 0), to: "c8 d")
        #expect(overridden == "\\once \\override Beam.extra-offset = #'(0 . 1) c8 d")
        let moved = link("Beam", "note-event", column: column(of: "c8", in: overridden))
        #expect(try TweakWriter.apply(offset, for: moved, to: overridden) == "\\once \\override Beam.extra-offset = #'(1 . -0.5) c8 d")
    }

    @Test func tweaksTupletsAsMusic() throws {
        let text = "\\tuplet 3/2 { c4 d e }"
        let bracket = link("TupletBracket", "tuplet-span-event", column: 0)
        let once = try TweakWriter.apply(offset, for: bracket, to: text)
        #expect(once == "\\tweak TupletBracket.extra-offset #'(1 . -0.5) \\tuplet 3/2 { c4 d e }")
        #expect(try TweakWriter.apply(.set(property: "extra-offset", grob: nil, value: .pair(2, 2)), for: bracket, to: once)
                == "\\tweak TupletBracket.extra-offset #'(2 . 2) \\tuplet 3/2 { c4 d e }")
    }

    @Test func countsColumnsLikeLilyPond() throws {
        // A tab is one character, 🎵 one character but two UTF-16 units.
        let text = "{\n\tc4^\"🎵\" d4-> }"
        #expect(try TweakWriter.apply(offset, for: link("Script", "articulation-event", line: 2, column: 10), to: text)
                == "{\n\tc4^\"🎵\" d4-\\tweak extra-offset #'(1 . -0.5) -> }")
    }

    @Test func refusesWhenTheSourceChanged() {
        #expect(throws: TweakWriter.Failure.locationNotFound) {
            try TweakWriter.apply(self.offset, for: self.link("Script", "articulation-event", line: 3, column: 0), to: "c4->")
        }
        #expect(throws: TweakWriter.Failure.locationNotFound) {
            try TweakWriter.apply(self.offset, for: self.link("Script", "articulation-event", column: 40), to: "c4->")
        }
        #expect(throws: TweakWriter.Failure.unexpectedText("“c4->”")) {
            try TweakWriter.apply(self.offset, for: self.link("Script", "articulation-event", column: 0), to: "c4->")
        }
    }

    @Test func formatsNumbers() {
        #expect(TweakWriter.format(1) == "1" && TweakWriter.format(-0.004) == "0")
        #expect(TweakWriter.format(2.346) == "2.35" && TweakWriter.format(-1.5) == "-1.5")
        #expect(TweakValue.pair(0.1, -2).scheme == "#'(0.1 . -2)" && TweakValue.number(3).scheme == "#3")
    }
}

@Suite struct PreviewSettingsTests {
    let lilypond = URL(fileURLWithPath: "/opt/homebrew/bin/lilypond")
    let source = URL(fileURLWithPath: "/tmp/score.ly")
    let settings = URL(fileURLWithPath: "/Applications/Frescobaldi.app/Contents/Resources/LilyPond/fmac-edit.ly")

    @Test func onlyForPreviews() {
        let preview = EngraveJob(lilypond: lilypond, source: source, mode: .preview, previewSettings: settings)
        #expect(preview.arguments.contains("-dinclude-settings=" + settings.path))
        let publish = EngraveJob(lilypond: lilypond, source: source, mode: .publish, previewSettings: settings)
        #expect(!publish.arguments.contains { $0.hasPrefix("-dinclude-settings") })
        // A project's own settings file wins: LilyPond takes only one.
        let own = EngraveJob(lilypond: lilypond, source: source, mode: .preview,
                             extraArguments: ["-dinclude-settings=house.ly"], previewSettings: settings)
        #expect(own.arguments.filter { $0.hasPrefix("-dinclude-settings") } == ["-dinclude-settings=house.ly"])
        #expect(EngraveJob(command: "make", directory: URL(fileURLWithPath: "/tmp")).arguments == ["-c", "make"])
    }
}
