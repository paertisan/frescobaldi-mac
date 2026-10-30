import Foundation
import Testing
@testable import FrescobaldiCore

/// `text` with `removing` UTF-16 units at `location` replaced by `inserting`.
private func edit(_ text: String, at location: Int, removing: Int = 0, inserting: String = "") -> LineEdit {
    let old = text as NSString
    let new = old.replacingCharacters(in: NSRange(location: location, length: removing), with: inserting) as NSString
    return LineEdit(location: location, oldLength: removing, newLength: (inserting as NSString).length,
                    old: LineIndex(old), new: LineIndex(new))
}

private func message(_ file: String, _ line: Int, _ severity: LilyPondMessage.Severity) -> LilyPondMessage {
    LilyPondMessage(file: file, line: line, column: 1, severity: severity, message: "m", logLine: line)
}

@Suite struct LineEditTests {
    // Lines: 1 "one" (0…3), 2 "two" (4…7), 3 "three" (8…13), 4 "four" (14…18), 5 "".
    let text = "one\ntwo\nthree\nfour\n"

    @Test func typingInALineMovesNothing() {
        #expect(edit(text, at: 5, inserting: "x").isIdentity)
        #expect(edit(text, at: 4, removing: 3, inserting: "2").isIdentity)
        #expect(edit(text, at: 5, inserting: "x").map(2) == 2)
    }

    @Test func newLines() {
        // Splitting line 2: its start stays, the lines after move down.
        let split = edit(text, at: 5, inserting: "\n")
        #expect([1, 2, 3, 4].map(split.map) == [1, 2, 4, 5])
        // A line inserted before line 2 moves line 2 too.
        let before = edit(text, at: 4, inserting: "x\n")
        #expect([1, 2, 3].map(before.map) == [1, 3, 4])
    }

    @Test func removedLines() {
        // "two\nthree\n" deleted.
        let deleted = edit(text, at: 4, removing: 10)
        #expect([1, 2, 3, 4].map(deleted.map) == [1, nil, nil, 2])
        #expect(deleted.nearest(3) == 2)
        // Joining lines 2 and 3.
        let joined = edit(text, at: 7, removing: 1)
        #expect([2, 3, 4].map(joined.map) == [2, 2, 3])
        // "o\nth" replaced: the rest of line 3 joins line 2.
        let replaced = edit(text, at: 6, removing: 4, inserting: "X")
        #expect([2, 3, 4].map(replaced.map) == [2, 2, 3])
    }
}

@Suite struct IssueMarkersTests {
    @Test func aRunReplacesTheMarkersOfTheFilesItRead() {
        var markers = IssueMarkers()
        let changed = markers.update(with: [
            message("/p/a.ly", 3, .error),
            message("/p/b.ily", 2, .warning), message("/p/b.ily", 2, .error), message("/p/b.ily", 5, .warning),
            LilyPondMessage(file: "", line: 0, column: 0, severity: .warning, message: "Unknown paper size: bogus"),
        ], covering: ["/p/a.ly", "/p/b.ily", "/p/c.ily"])
        #expect(markers.lines(for: "/p/a.ly") == [3: .error])
        #expect(markers.lines(for: "/p/b.ily") == [2: .error, 5: .warning], "an error wins over a warning")
        #expect(changed == ["/p/a.ly", "/p/b.ily"])

        // Another target, with an error in a file a.ly doesn't read.
        markers.update(with: [message("/p/c.ily", 1, .error)], covering: ["/p/other.ly", "/p/c.ily"])
        #expect(markers.lines(for: "/p/a.ly") == [3: .error])

        // A clean run of a.ly clears its files, also the included one, and
        // leaves c.ily alone.
        let cleared = markers.update(with: [], covering: ["/p/a.ly", "/p/b.ily"])
        #expect(cleared == ["/p/a.ly", "/p/b.ily"])
        #expect(markers.lines(for: "/p/a.ly").isEmpty && markers.lines(for: "/p/b.ily").isEmpty)
        #expect(markers.lines(for: "/p/c.ily") == [1: .error])
        let unchanged = markers.update(with: [], covering: ["/p/a.ly"])
        #expect(unchanged.isEmpty)
    }

    @Test func markersAndMessagesFollowEdits() {
        var markers = IssueMarkers()
        markers.update(with: [message("/p/b.ily", 2, .warning), message("/p/b.ily", 3, .error)], covering: [])
        let text = "one\ntwo\nthree\nfour\n"
        var moved = markers.apply(edit(text, at: 5, inserting: "x"), to: "/p/b.ily")
        #expect(!moved)
        moved = markers.apply(edit(text, at: 0, inserting: "\n\n"), to: "/p/b.ily")
        #expect(moved)
        #expect(markers.lines(for: "/p/b.ily") == [4: .warning, 5: .error])
        // Joining the two lines keeps the error.
        moved = markers.apply(edit("\n\n" + text, at: 9, removing: 1), to: "/p/b.ily")
        #expect(moved)
        #expect(markers.lines(for: "/p/b.ily") == [4: .error])
        moved = markers.apply(edit(text, at: 0, inserting: "\n"), to: "/p/other.ily")
        #expect(!moved)

        let messages = [message("/p/b.ily", 2, .warning), message("/p/a.ly", 2, .error)]
        let shifted = IssueMarkers.move(messages, by: edit(text, at: 0, inserting: "\n"), in: "/p/b.ily")
        #expect(shifted.map(\.line) == [3, 2])
    }
}
