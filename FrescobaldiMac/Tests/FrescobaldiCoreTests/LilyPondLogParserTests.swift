import Foundation
import Testing
@testable import FrescobaldiCore

/// Shaped like LilyPond 2.26.0 output (stderr) with errors.
private let sampleLog = """
GNU LilyPond 2.26.0 (running Guile 3.0)
Processing `/Users/rwr/Music/test.ly'
Parsing...
/Users/rwr/Music/test.ly:4:9: error: not a note name: x
  c d e
        x f g
/Users/rwr/Music/test.ly:7:3: warning: barcheck failed at: 1/4
  c4
     | d1
/Users/rwr/Music/include dir/part.ily:2:1: programming error: something odd
Interpreting music...
Preprocessing graphical objects...
Finding the ideal number of pages...
Fitting music on 1 page...
Drawing systems...
Converting to `test.pdf'...
MIDI output to `test.midi'...
fatal error: failed files: "/Users/rwr/Music/test.ly"
"""

@Suite struct LilyPondLogParserTests {
    @Test func parsesMessagesWithContext() throws {
        let messages = LilyPondLogParser.parse(sampleLog)
        #expect(messages.count == 3)

        let error = try #require(messages.first)
        #expect(error.file == "/Users/rwr/Music/test.ly")
        #expect(error.line == 4 && error.column == 9)
        #expect(error.severity == .error && error.severity.isError)
        #expect(error.message == "not a note name: x")
        #expect(error.context == ["  c d e", "        x f g"])
        #expect(error.logLine == 3)

        #expect(messages[1].severity == .warning && !messages[1].severity.isError)
        #expect(messages[1].message == "barcheck failed at: 1/4")
        #expect(messages[1].context.count == 2)

        // Spaces in the path; context stops at progress lines.
        #expect(messages[2].file == "/Users/rwr/Music/include dir/part.ily")
        #expect(messages[2].severity == .programmingError)
        #expect(messages[2].context.isEmpty)
    }

    @Test func columnIsOneBasedAndLinkIsZeroBased() throws {
        let message = try #require(LilyPondLogParser.parseMessage("/a.ly:2:1: error: x"))
        #expect(message.column == 1)
        #expect(message.link == TextEditLink(path: "/a.ly", line: 2, startColumn: 0, endColumn: 0))
    }

    @Test func skipsFailedFilesSummary() {
        #expect(LilyPondLogParser.parseMessage(#"fatal error: failed files: "/a.ly""#) == nil)
        #expect(LilyPondLogParser.parseMessage(#"/a.ly:1:1: fatal error: failed files: "/a.ly""#) == nil)
        let fatal = LilyPondLogParser.parseMessage("/a.ly:1:1: fatal error: cannot find file: `x.ily'")
        #expect(fatal?.severity == .fatalError)
    }

    @Test func ignoresOtherLines() {
        #expect(LilyPondLogParser.parseMessage("Parsing...") == nil)
        #expect(LilyPondLogParser.parseMessage("warning: no \\version statement found") == nil)
        #expect(LilyPondLogParser.parseMessage("/a.ly:x:1: error: y") == nil)
    }

    @Test func outputFiles() {
        #expect(LilyPondLogParser.outputFiles(in: sampleLog) == ["test.pdf", "test.midi"])
        let curly = "Converting to ‘/tmp/a b.pdf’...\nConverting to `x-1.pdf'...\nConverting to `x-1.pdf'..."
        #expect(LilyPondLogParser.outputFiles(in: curly) == ["/tmp/a b.pdf", "x-1.pdf"])
    }

    @Test func handlesCRLF() {
        let log = "/a.ly:1:2: error: bad\r\n  c\r\n   d\r\n"
        let messages = LilyPondLogParser.parse(log)
        #expect(messages.count == 1)
        #expect(messages.first?.context == ["  c", "   d"])
    }
}
