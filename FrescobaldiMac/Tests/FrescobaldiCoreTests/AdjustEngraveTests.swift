#if canImport(PDFKit)
import Foundation
import PDFKit
import Testing
@testable import FrescobaldiCore

/// Engraves with Resources/LilyPond/fmac-edit.ly and reads the links back
/// with PDFKit, as the preview does. Needs LilyPond.
private let installedLilyPond = LilyPondLocator.locate(userSetting: nil)

@Suite(.enabled(if: installedLilyPond != nil, "LilyPond isn't installed"))
struct AdjustEngraveTests {
    static let lilypond = installedLilyPond
    static let settings = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LilyPond/fmac-edit.ly")

    /// Every kind of object fmac-edit.ly links, and a tab and a non-ASCII
    /// text before some of them.
    static let score = """
        \\version "2.24.0"
        \\new PianoStaff <<
          \\new Staff = "right" \\relative c'' {
            c4-> d^. e_- f\\p |
        \tg4-1 a-\\markup { dolce } b\\< c\\! |
            c8( d e f) g4~ g |
            \\tuplet 3/2 { c4 d e } \\tuplet 3/2 { c8[ d e] } f4 |
            a4\\( b c\\) <c-1 e-3 g-5>4\\f |
            c8^"é🎵" d-> e f g a b c( | \\break
            d1) |
          }
          \\new Staff = "left" { \\clef bass c4\\sustainOn d\\sustainOff e f | g1 | c1 | c1 | c1 | c1 | c1 }
        >>

        """

    struct Object {
        var link: GrobLink
        var page: Int
        var bounds: CGRect
    }

    func engrave(_ text: String, in folder: URL, settings: URL? = AdjustEngraveTests.settings,
                 mode: EngraveJob.Mode = .preview) async throws -> (EngraveJob.Result, [Object]) {
        let source = folder.appendingPathComponent("score.ly")
        try Data(text.utf8).write(to: source)
        let job = EngraveJob(lilypond: try #require(Self.lilypond), source: source, mode: mode, previewSettings: settings)
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let pdf = try #require(result.pdfs.first, "no PDF: \(result.log)")
        let document = try #require(PDFDocument(url: pdf))
        var objects: [Object] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url, let link = GrobLink(url: url) {
                    objects.append(Object(link: link, page: index, bounds: annotation.bounds))
                }
            }
        }
        return (result, objects)
    }

    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fmac-adjust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func linksEveryObjectWithoutNewWarnings() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (plain, none) = try await engrave(Self.score, in: folder, settings: nil)
        #expect(none.isEmpty)
        let (result, objects) = try await engrave(Self.score, in: folder)
        #expect(result.succeeded)
        #expect(result.messages.count == plain.messages.count, "\(result.messages)")
        let names = Set(objects.map(\.link.grob))
        #expect(names == ["Script", "TextScript", "DynamicText", "Fingering", "Slur", "PhrasingSlur", "Tie", "Hairpin",
                          "SustainPedal", "TupletBracket", "Beam"])
        // The links point at the events, in LilyPond's columns.
        let text = Self.score as NSString
        for object in objects {
            let edit = try? TweakWriter.edit(.set(property: "color", grob: nil, value: .number(0)), for: object.link, in: text)
            #expect(edit != nil, "\(object.link.summary) at column \(object.link.column)")
        }
        let fingering = try #require(objects.first { $0.link.grob == "Fingering" && $0.link.line == 5 })
        #expect(fingering.link.column == 3, "a tab is one column")
        let accent = try #require(objects.first { $0.link.grob == "Script" && $0.link.line == 9 })
        #expect(accent.link.column == 13 && accent.link.label == "accent", "é🎵 are one column each")
        // A broken slur has a link per piece; an automatic beam its first note.
        #expect(objects.filter { $0.link.grob == "Slur" && $0.link.line == 9 }.map(\.link.piece).sorted() == [1, 2])
        #expect(objects.contains { $0.link.grob == "Beam" && $0.link.event == "note-event" })
        // Export PDF and publishing: no links.
        let (_, published) = try await engrave(Self.score, in: folder, mode: .publish)
        #expect(published.isEmpty)
    }

    @Test func extraOffsetMovesTheObject() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, before) = try await engrave(Self.score, in: folder)
        func find(_ objects: [Object], _ grob: String, line: Int) throws -> Object {
            try #require(objects.first { $0.link.grob == grob && $0.link.line == line })
        }
        let accent = try #require(before.first { $0.link.grob == "Script" && $0.link.line == 4 && $0.link.label == "accent" })
        let move = GrobLink.Point(12, -7)
        let tweak = try #require(accent.link.tweak(.extraOffset, movedBy: move))
        let text = try TweakWriter.apply(tweak, for: accent.link, to: Self.score)
        #expect(text.contains("c4-\\tweak extra-offset #'("))
        let (result, after) = try await engrave(text, in: folder)
        #expect(result.succeeded && result.messages.isEmpty, "\(result.log)")
        let moved = try #require(after.first { $0.link.grob == "Script" && $0.link.line == 4 && $0.link.label == "accent" })
        #expect(moved.link.column == accent.link.column)
        #expect(abs(moved.bounds.minX - accent.bounds.minX - move.x) <= 0.5)
        #expect(abs(moved.bounds.minY - accent.bounds.minY - move.y) <= 0.5)

        // Dragging it again updates the same tweak.
        let again = try #require(moved.link.tweak(.extraOffset, movedBy: GrobLink.Point(-12, 7)))
        let back = try TweakWriter.apply(again, for: moved.link, to: text)
        #expect(back.components(separatedBy: "\\tweak").count == 2)
        let (_, restored) = try await engrave(back, in: folder)
        let home = try #require(restored.first { $0.link.grob == "Script" && $0.link.line == 4 && $0.link.label == "accent" })
        #expect(abs(home.bounds.minX - accent.bounds.minX) <= 0.5 && abs(home.bounds.minY - accent.bounds.minY) <= 0.5)
    }

    @Test func everyKindOfTweakEngravesCleanly() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, objects) = try await engrave(Self.score, in: folder)
        var text = Self.score
        // Later lines first, so earlier links stay valid.
        let ss = objects[0].link.pointsPerStaffSpace
        var tweaks: [(GrobLink, Tweak)] = []
        for object in objects.sorted(by: { ($0.link.line, $0.link.column) > ($1.link.line, $1.link.column) }) {
            let link = object.link
            let tweak: Tweak?
            switch link.grob {
            case "Slur", "Tie", "PhrasingSlur": tweak = link.shape(movingPoint: 1, by: .init(0, ss))
            case "Beam": tweak = link.beamOffset(left: ss, right: 0)
            case "DynamicText", "Hairpin", "SustainPedal": tweak = link.tweak(.staffPadding, movedBy: .init(0, -ss))
            case "TupletBracket": tweak = link.tweak(.padding, movedBy: .init(0, ss))
            case "TextScript": tweak = link.tweak(.outsideStaffPadding, movedBy: .init(0, ss))
            case "Fingering": tweak = link.tweak(.xOffset, movedBy: .init(ss, 0))
            default: tweak = link.tweak(.padding, movedBy: .init(0, ss / 2))
            }
            if let tweak { tweaks.append((link, tweak)) }
        }
        var done = Set<String>()
        for (link, tweak) in tweaks {
            // One per event: pieces of a broken slur share it, as do a
            // dynamic and the hairpin whose spanner holds it.
            let key = "\(link.line):\(link.column):\(tweak)"
            guard done.insert(key).inserted else { continue }
            text = try TweakWriter.apply(tweak, for: link, to: text)
        }
        let (result, after) = try await engrave(text, in: folder)
        #expect(result.succeeded && result.messages.isEmpty, "\(text)\n\(result.log)")
        #expect(Set(after.map(\.link.grob)).count == 11)
        // The new links show the values reached the right objects.
        func same(_ grob: String, as old: Object) throws -> GrobLink {
            try #require(after.first { $0.link.grob == grob && $0.link.line == old.link.line
                && $0.link.label == old.link.label && $0.link.piece == old.link.piece }).link
        }
        let pedal = try #require(objects.first { $0.link.grob == "SustainPedal" })
        #expect(try same("SustainPedal", as: pedal).staffPadding == (pedal.link.staffPadding ?? 0) + 1)
        let dynamic = try #require(objects.first { $0.link.grob == "DynamicText" && $0.link.label == "p" })
        #expect(try same("DynamicText", as: dynamic).staffPadding == (dynamic.link.staffPadding ?? 0) + 1)
        let beam = try #require(objects.first { $0.link.grob == "Beam" && $0.link.event == "beam-event" })
        let beamAfter = try same("Beam", as: beam)
        #expect(abs((beamAfter.positions?.x ?? 0) - (beam.link.positions?.x ?? 0) - 1) < 0.01)
        #expect(abs((beamAfter.positions?.y ?? 0) - (beam.link.positions?.y ?? 0)) < 0.01)
        let tie = try #require(objects.first { $0.link.grob == "Tie" })
        let tieAfter = try same("Tie", as: tie)
        #expect(abs(tieAfter.controlPoints[1].y - tie.link.controlPoints[1].y - 1) < 0.05)
        #expect(abs(tieAfter.controlPoints[2].y - tie.link.controlPoints[2].y) < 0.05)
        #expect(text.contains("\\once \\offset positions #'(1 . 0) Beam"))
        #expect(text.contains("\\tweak TupletBracket.padding"))
    }
}
#endif
