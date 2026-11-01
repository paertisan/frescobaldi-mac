import Foundation
import Testing
@testable import FrescobaldiCore

private let lilypondForTables = LilyPondLocator.locate(userSetting: nil)

/// Engraves piano tables with Resources/LilyPond/piano-tables.ily: no
/// errors or warnings, and the MIDI plays every note once, at its time.
/// Needs LilyPond. Times are MIDI ticks, 384 per quarter note.
@Suite(.enabled(if: lilypondForTables != nil, "LilyPond isn't installed"))
struct PianoTableEngraveTests {
    static let include = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LilyPond/piano-tables.ily")

    /// `music` in the upper staff of a piano staff whose lower staff only
    /// has skips, as the New Score wizard's piano has them.
    func engrave(_ music: String) async throws -> (EngraveJob.Result, [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("piano-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: Self.include, to: folder.appendingPathComponent("piano-tables.ily"))
        let source = folder.appendingPathComponent("score.ly")
        try Data("""
            \\version "2.24.0"
            \\include "piano-tables.ily"
            music = {
            \(music)
            }
            \\score {
              \\new PianoStaff <<
                \\new Staff = "right" { \\music }
                \\new Staff = "left" { \\clef bass s1*4 }
              >>
              \\layout { }
              \\midi { }
            }

            """.utf8).write(to: source)
        let job = EngraveJob(lilypond: try #require(lilypondForTables), source: source, mode: .publish)
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let midi = try #require(result.midis.first, "no MIDI: \(result.log)")
        return (result, try MIDINotes.read(midi))
    }

    func check(_ music: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (result, notes) = try await engrave(music)
        #expect(result.succeeded, "\(result.log)", sourceLocation: sourceLocation)
        #expect(result.messages.isEmpty, "\(result.messages.map(\.message))", sourceLocation: sourceLocation)
        #expect(notes == expected.split(separator: " ").map(String.init), sourceLocation: sourceLocation)
    }

    @Test func sixteenthsCrossingBetweenTheStaves() async throws {
        try await check("""
            \\pianoTable
              #'(C - - - - - - -)
              { \\col c''16[ \\col s \\col e'' \\col s  \\col g'' \\col s  \\col e'' \\col s] \\col }
              { \\col s16    \\col g \\col s   \\col c' \\col s   \\col e' \\col s   \\col c' \\col }
            r2
            """, "0:72 96:55 192:76 288:60 384:79 480:64 576:76 672:60")
    }

    @Test func beamAboveThenBelow() async throws {
        try await check("""
            \\pianoTable
              #'(U - D -)
              { \\col c''8[ \\col s  \\col e''8[ \\col s  \\col }
              { \\col s8    \\col g] \\col s8    \\col c] \\col }
            r2
            """, "0:72 192:55 384:76 576:48")
    }

    @Test func chordsSplitAcrossTheStaves() async throws {
        // Both cells have notes: the lower ones join the upper stems.
        try await check("""
            \\pianoTable
              #'(U D)
              { \\col <e' g'>4 \\col <f' a'>4 \\col }
              { \\col c4       \\col f,4      \\col }
            r2
            """, "0:48 0:64 0:67 384:41 384:65 384:69")
    }

    @Test func noCrossStaffAndRests() async throws {
        try await check("""
            \\pianoTable
              #'(N -)
              { \\col c''4 \\col r4  \\col }
              { \\col c4   \\col g,4 \\col }
            r2
            """, "0:48 0:72 384:43")
    }

    @Test func tripletAcrossTheStaves() async throws {
        // `\\col } \\col` around the tuplet's brace is one column boundary.
        try await check("""
            \\pianoTable
              #'(D - - -)
              { \\tuplet 3/2 { \\col c''8[ \\col s \\col e'' \\col } \\col r4 \\col }
              { \\tuplet 3/2 { \\col s8    \\col g \\col s]  \\col } \\col s4 \\col }
            r2
            """, "0:72 128:55 256:76")
    }

    @Test func risingArpeggioAndAChordBelow() async throws {
        try await check("""
            \\pianoTable
              #'(U - - - - -)
              { \\col s8  \\col s \\col s  \\col e'8 \\col g' \\col c''  \\col }
              { \\col c8[ \\col g \\col c' \\col s   \\col s  \\col s]   \\col }
            \\pianoTable
              #'(C -)
              { \\col s8     \\col g'8] \\col }
              { \\col <c e>8[ \\col s    \\col }
            r4
            """, "0:48 192:55 384:60 576:64 768:67 960:72 1152:48 1152:52 1344:67")
    }

    @Test func withoutBeamList() async throws {
        try await check("""
            \\pianoTable
              { \\col c''8[ \\col s \\col e'' \\col s  \\col }
              { \\col s8    \\col g \\col s   \\col c] \\col }
            r2
            """, "0:72 192:55 384:76 576:48")
    }

    @Test func relativeRows() async throws {
        // A row may be \\relative itself; the table ignores an outer one.
        try await check("""
            \\relative c' {
              \\pianoTable
                #'(C - - -)
                \\relative c'' { \\col c16[ \\col s  \\col e \\col s  \\col }
                \\relative c   { \\col s16  \\col g' \\col s \\col c] \\col }
              d2
            }
            """, "0:72 96:55 192:76 288:60 384:62")
    }

    @Test func polyphony() async throws {
        try await check("""
            \\pianoTablePoly 2 {
              { \\col c'''4 \\col d''' \\col e''' \\col f''' \\col }
              { \\col a''2  \\col      \\col b''2  \\col      \\col }
              { \\col c'1   \\col      \\col       \\col      \\col }
              { \\col g4    \\col a2.  \\col       \\col      \\col }
            }
            \\pianoTablePoly 1 {
              { \\col \\tuplet 3/2 { \\col e''8 \\col f'' \\col g'' \\col } \\col c'''2 \\col }
              { \\col c4                                     \\col g,2   \\col }
            }
            """, "0:55 0:60 0:81 0:84 384:57 384:86 768:83 768:88 1152:89 1536:48 1536:76 1664:77 1792:79 1920:43 1920:84")
    }

    // Spontini's examples' music, written as our tables (not their code).

    @Test func unisonSplitWithDynamics() async throws {
        // easy-cross-staff example 1: a unison shared by both staves.
        try await check("""
            \\pianoTable
              #'(U -)
              { \\col c'8\\mf[ \\col c'] \\col }
              { \\col s8      \\col c'  \\col }
            r2.
            """, "0:60 192:60 192:60")
    }

    @Test func fiveColumnsCUDN() async throws {
        // easy-cross-staff example 2, table 11: beams C, -, U, D, N. (Its
        // kneed pair is two middle Cs, too close for a beam between; here
        // E and G.)
        try await check("""
            \\pianoTable
              #'(C  -     U    D    N)
              { \\col e'8[ \\col s     \\col c'4 \\col c' \\col c' \\col }
              { \\col s8   \\col g]    \\col c4  \\col c  \\col c  \\col }
            """, "0:64 192:55 384:48 384:60 768:48 768:60 1152:48 1152:60")
    }

    @Test func fourVoicesOverTwoStaves() async throws {
        // tabular-poly-example: two voices in each staff over one bar.
        try await check("""
            \\pianoTablePoly 2 {
              { \\col c'''4 \\col d'''4 \\col e''' \\col f''' \\col }
              { \\col a'2   \\col       \\col b'2  \\col      \\col }
              { \\col c'1   \\col       \\col      \\col      \\col }
              { \\col g4    \\col a2.   \\col      \\col      \\col }
            }
            """, "0:55 0:60 0:69 0:84 384:57 384:86 768:71 768:88 1152:89")
    }
}

/// Note-ons of a standard MIDI file as "tick:pitch", sorted.
enum MIDINotes {
    struct Failure: Error {}

    static func read(_ url: URL) throws -> [String] {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count > 14, d[0..<4].elementsEqual("MThd".utf8) else { throw Failure() }
        let tracks = Int(d[10]) << 8 | Int(d[11])
        var i = 14
        var notes: [(Int, Int)] = []
        func variable(_ j: inout Int) -> Int {
            var value = 0
            while j < d.count {
                let b = d[j]; j += 1
                value = value << 7 | Int(b & 0x7F)
                if b < 0x80 { break }
            }
            return value
        }
        for _ in 0..<tracks {
            guard i + 8 <= d.count, d[i..<i + 4].elementsEqual("MTrk".utf8) else { throw Failure() }
            let length = Int(d[i + 4]) << 24 | Int(d[i + 5]) << 16 | Int(d[i + 6]) << 8 | Int(d[i + 7])
            var j = i + 8
            let end = j + length
            var tick = 0
            var status: UInt8 = 0
            while j < end {
                tick += variable(&j)
                let b = d[j]
                if b == 0xFF { j += 2; j += variable(&j); continue }
                if b == 0xF0 || b == 0xF7 { j += 1; j += variable(&j); continue }
                if b & 0x80 != 0 { status = b; j += 1 }
                switch status & 0xF0 {
                case 0xC0, 0xD0: j += 1
                case 0x90:
                    if d[j + 1] > 0 { notes.append((tick, Int(d[j]))) }
                    j += 2
                default: j += 2
                }
            }
            i = end
        }
        return notes.sorted { $0 < $1 }.map { "\($0.0):\($0.1)" }
    }
}
