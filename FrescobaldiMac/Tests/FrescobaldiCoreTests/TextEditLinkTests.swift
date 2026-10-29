import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct TextEditLinkTests {
    @Test func parsesLilyPondLink() throws {
        let link = try #require(TextEditLink(string: "textedit:///Users/rwr/Music/song.ly:12:4:7"))
        #expect(link == TextEditLink(path: "/Users/rwr/Music/song.ly", line: 12, startColumn: 4, endColumn: 7))
    }

    @Test func percentDecodesAndKeepsColonsInPath() throws {
        let link = try #require(TextEditLink(string: "textedit:///Users/rwr/My%20Scores/a:b%C3%BC.ly:3:0:2"))
        #expect(link.path == "/Users/rwr/My Scores/a:bü.ly")
        #expect(link.line == 3 && link.startColumn == 0 && link.endColumn == 2)
    }

    @Test func fromURL() throws {
        let url = try #require(URL(string: "textedit:///tmp/x.ly:1:2:3"))
        #expect(TextEditLink(url: url)?.path == "/tmp/x.ly")
    }

    @Test func acceptsTwoNumberForm() throws {
        let link = try #require(TextEditLink(string: "textedit:///tmp/x.ly:5:9"))
        #expect(link.line == 5 && link.startColumn == 9 && link.endColumn == 9)
    }

    @Test func rejectsOtherLinks() {
        #expect(TextEditLink(string: "https://lilypond.org") == nil)
        #expect(TextEditLink(string: "textedit:///tmp/x.ly") == nil)
        #expect(TextEditLink(string: "textedit:///tmp/x.ly:0:1:2") == nil, "lines are 1-based")
        #expect(TextEditLink(string: "textedit://") == nil)
        #expect(TextEditLink(string: "textedit:///tmp/x.ly:a:b:2") == nil)
    }

    @Test func rangeInText() throws {
        let text = "\\version \"2.26.0\"\n{ cis'4 d }\n" as NSString
        let link = TextEditLink(path: "/x.ly", line: 2, startColumn: 2, endColumn: 6)
        let range = try #require(link.range(in: text))
        #expect(text.substring(with: range) == "cis'")
    }

    @Test func columnsCountScalarsNotUTF16() throws {
        // 🎵 is one column for LilyPond but two UTF-16 units.
        let text = "\\markup \"🎵\" c4" as NSString
        let link = TextEditLink(path: "/x.ly", line: 1, startColumn: 12, endColumn: 13)
        let range = try #require(link.range(in: text))
        #expect(text.substring(with: range) == "c")
    }

    @Test func rangeClampsAndRejectsMissingLines() {
        let text = "c d\ne" as NSString
        #expect(TextEditLink(path: "", line: 3, startColumn: 0, endColumn: 1).range(in: text) == nil)
        let clamped = TextEditLink(path: "", line: 2, startColumn: 0, endColumn: 99).range(in: text)
        #expect(clamped == NSRange(location: 4, length: 1))
    }

    @Test func positionRoundTrip() {
        let text = "a\r\nbé 🎵 c\n" as NSString
        let location = text.range(of: "c").location
        let position = TextEditLink.position(of: location, in: text)
        #expect(position.line == 2 && position.column == 5)
        let link = TextEditLink(path: "", line: position.line, startColumn: position.column,
                                endColumn: position.column + 1)
        #expect(link.range(in: text) == NSRange(location: location, length: 1))
    }

    @Test func lineHelpers() {
        let text = "one\ntwo\r\nthree\n" as NSString
        #expect(TextLines.range(ofLine: 1, in: text) == NSRange(location: 0, length: 3))
        #expect(TextLines.range(ofLine: 2, in: text) == NSRange(location: 4, length: 3))
        #expect(TextLines.range(ofLine: 3, in: text) == NSRange(location: 9, length: 5))
        #expect(TextLines.range(ofLine: 4, in: text) == NSRange(location: 15, length: 0))
        #expect(TextLines.range(ofLine: 5, in: text) == nil)
        #expect(TextLines.lineNumber(at: 0, in: text) == 1)
        #expect(TextLines.lineNumber(at: 9, in: text) == 3)
        #expect(TextLines.lineNumber(at: text.length, in: text) == 4)
    }
}
