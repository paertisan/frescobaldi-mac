import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct DocumentOutlineTests {
    @Test func outline() {
        let source = """
        \\version "2.26.0"
        \\include "english.ly"

        %% Melody
        melody = \\relative c'' {
          \\header { piece = "no" }   % inside music: not listed
          c4 d e f
        }

        words = \\lyricmode { la la }
        % plain comment

        \\book {
          \\header { title = "Song" }
          \\score {
            \\new Staff \\melody
            \\layout { }
            \\midi { }
          }
        }
        \\paper { indent = 0 }
        """
        let items = DocumentOutline.items(in: source as NSString)
        let summary = items.map { "\($0.level) \($0.kind.rawValue) \($0.title) @\($0.line)" }
        #expect(summary == [
            "0 version 2.26.0 @1",
            "0 include english.ly @2",
            "0 marker Melody @4",
            "0 assignment melody @5",
            "0 assignment words @10",
            "0 book \\book @13",
            "1 header \\header @14",
            "1 score \\score @15",
            "2 layout \\layout @17",
            "2 midi \\midi @18",
            "0 paper \\paper @21",
        ])
        let melody = items[3]
        #expect((source as NSString).substring(with: melody.range) == "melody")
    }

    @Test func emptyAndUnfinished() {
        #expect(DocumentOutline.items(in: "" as NSString).isEmpty)
        let items = DocumentOutline.items(in: "\\include\n\\score { c" as NSString)
        #expect(items.map(\.kind) == [.include, .score])
        #expect(items[0].title == "\\include")
    }
}
