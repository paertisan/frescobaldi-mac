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
        #expect(LilyPondLogParser.parseMessage("/a.ly:x: error: y") == nil)
        #expect(LilyPondLogParser.parseMessage("In procedure car: wrong type") == nil)
    }

    // The logs below are LilyPond 2.26.0's.

    @Test func keepsMessagesWithoutALocation() throws {
        let log = """
        Processing `w1.ly'
        Parsing...
        warning: Unknown paper size: bogus
        Interpreting music...
        Converting to `w1.pdf'...
        Success: compilation successfully completed
        """
        let messages = LilyPondLogParser.parse(log)
        let warning = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(warning.severity == .warning && warning.message == "Unknown paper size: bogus")
        #expect(!warning.isLocated && warning.file.isEmpty && warning.line == 0)
        #expect(warning.context.isEmpty)
        // Not tied to the folder a build command ran in.
        let resolved = LilyPondLogParser.resolvingPaths(messages, in: log, base: URL(fileURLWithPath: "/tmp"))
        #expect(resolved.first?.file == "")

        let fatal = LilyPondLogParser.parse("Changing working directory to: `out'\nfatal error: unable to change directory to: `out'\n")
        #expect(fatal.first?.severity == .fatalError && fatal.first?.isLocated == false)
    }

    @Test func messageWithLineButNoColumn() throws {
        let log = """
        w7.ly:1: warning: no \\version statement found, please add

        \\version "2.26.0"

        for future compatibility
        Interpreting music...
        """
        let messages = LilyPondLogParser.parse(log)
        let warning = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(warning.file == "w7.ly" && warning.line == 1 && warning.column == 0 && warning.isLocated)
        #expect(warning.message == "no \\version statement found, please add")
        #expect(warning.link.startColumn == 0)
    }

    @Test func keepsTheLineThatExplainsASchemeError() throws {
        let log = """
        w2.ly:2:2: error: Guile signaled an error for the expression beginning here
        #
         (define x (car '()))
        In procedure car: Wrong type argument in position 1 (expecting pair): ()
        Interpreting music...
        fatal error: failed files: "w2.ly"
        """
        let messages = LilyPondLogParser.parse(log)
        #expect(messages.count == 1)
        #expect(messages.first?.context == ["#", " (define x (car '()))",
                                            "In procedure car: Wrong type argument in position 1 (expecting pair): ()"])
    }

    @Test func dropsTheSearchPathFromContext() {
        let log = """
        w3.ly:2:10: error: cannot find file: `d.ily'
        (search path: `/opt/homebrew/share/lilypond/2.26.0/ly:/opt/homebrew/share/lilypond/2.26.0/ps:')
        \\include 
                 "d.ily"
        Interpreting music...
        """
        #expect(LilyPondLogParser.parse(log).first?.context == ["\\include ", "         \"d.ily\""])
    }

    @Test func columnOneAndBlankLinesEndContext() {
        let log = """
        w5.ly:3:1: error: unknown command: `\\bogus'

        \\bogus d }
        w4.ly:2:28: error: unknown command: `\\bogus'
        { c'4 \\times 2/3 { c d e } 
                                   \\bogus }

        Note: compilation failed and \\version outdated, did you
        update input syntax with convert-ly?
        """
        let messages = LilyPondLogParser.parse(log)
        #expect(messages.count == 2)
        #expect(messages.first?.context == ["", "\\bogus d }"])
        #expect(messages.last?.context.count == 2)
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
