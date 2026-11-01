import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct TableFormatterTests {
    func formatted(_ text: String, at needle: String = "\\pianoTable", cursor: String? = nil) -> (String, Int)? {
        let ns = text as NSString
        let location = ns.range(of: needle).location
        let caret = cursor.map { ns.range(of: $0).location } ?? location
        guard let edit = TableFormatter.format(at: location, in: ns, selection: NSRange(location: caret, length: 0))
        else { return nil }
        return (ns.replacingCharacters(in: edit.range, with: edit.replacement), edit.selection.location)
    }

    static let messy = """
        music = {
          \\pianoTable
            #'(C - -)
            { \\col c''8[ \\col s \\col e'' \\col }
            { \\col s8 \\col g' \\col s] \\col }
          r2
        }
        """

    static let tidy = """
        music = {
          \\pianoTable
            #'(    C          -       - )
            { \\col c''8[ \\col s  \\col e'' \\col }
            { \\col s8    \\col g' \\col s]  \\col }
          r2
        }
        """

    @Test func linesUpColumnsAndBeams() throws {
        let (text, _) = try #require(formatted(Self.messy))
        #expect(text == Self.tidy)
        #expect(formatted(Self.tidy) == nil, "already lined up")
        // From anywhere in the table.
        #expect(formatted(Self.messy, at: "g'")?.0 == Self.tidy)
        #expect(formatted("{ c4 d }", at: "c4") == nil)
    }

    @Test func findsTables() throws {
        let text = Self.tidy as NSString
        let table = try #require(TableFormatter.table(containing: text.range(of: "s]").location, in: text))
        #expect(table.rows.count == 3 && table.rows[0].isBeams)
        #expect(text.substring(with: table.rows[1].range).hasPrefix("{ \\col c''8["))
        #expect(TableFormatter.table(containing: text.range(of: "r2").location, in: text) == nil)
        // Locations that aren't in the text.
        #expect(TableFormatter.table(containing: NSNotFound, in: text) == nil)
        #expect(TableFormatter.table(containing: -1, in: text) == nil)
        #expect(TableFormatter.cell(after: text.length + 5, in: text) == nil)
        #expect(TableFormatter.format(at: NSNotFound, in: text, selection: NSRange(location: 0, length: 0)) == nil)
        #expect(TableFormatter.tables(in: text).count == 1)
        // A commented-out table isn't one.
        #expect(TableFormatter.tables(in: "% \\pianoTable { \\col c \\col } { \\col d \\col }").isEmpty)
    }

    @Test func keepsTheCaretInItsCell() throws {
        // Typing made the first cell longer: the other rows move along.
        let typed = Self.tidy.replacingOccurrences(of: "c''8[", with: "c''16[\\mf")
        let (text, caret) = try #require(formatted(typed, cursor: "\\mf"))
        #expect(text.contains("{ \\col c''16[\\mf \\col s  \\col e'' \\col }"))
        #expect(text.contains("{ \\col s8        \\col g' \\col s]  \\col }"))
        #expect((text as NSString).substring(from: caret).hasPrefix("\\mf \\col s"))
        // A space typed after a note stays, so the next one can follow it.
        let afterSpace = Self.messy.replacingOccurrences(of: "{ \\col s8 \\col", with: "{ \\col s8  \\col")
        let ns = afterSpace as NSString
        let location = ns.range(of: "s8").location + 3
        let edit = try #require(TableFormatter.format(at: location, in: ns, selection: NSRange(location: location, length: 0)))
        let result = ns.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        #expect(result.substring(with: NSRange(location: edit.selection.location - 3, length: 3)) == "s8 ")
    }

    @Test func linesUpCommentsAndPolyphony() throws {
        let text = """
            \\pianoTablePoly 2 {
              { \\col c'''4 \\col d''' \\col e''' \\col f''' \\col } % upper, voice 1
              { \\col a'2 \\col \\col b'2 \\col \\col } % upper, voice 2
              { \\col c'1 \\col \\col \\col \\col }
            }
            """
        let (result, _) = try #require(formatted(text))
        #expect(result == """
            \\pianoTablePoly 2 {
              { \\col c'''4 \\col d''' \\col e''' \\col f''' \\col }  % upper, voice 1
              { \\col a'2   \\col      \\col b'2  \\col      \\col }  % upper, voice 2
              { \\col c'1   \\col      \\col      \\col      \\col }
            }
            """)
    }

    @Test func tupletsKeepTheirMarkers() throws {
        let text = """
            \\pianoTable
              #'(D - - -)
              { \\tuplet 3/2 { \\col c''8[ \\col s \\col e'' \\col } \\col r4 \\col }
              { \\tuplet 3/2 { \\col s8 \\col g' \\col s] \\col } \\col s4 \\col }
            """
        let (result, _) = try #require(formatted(text))
        let lines = result.split(separator: "\n").map(String.init)
        // Every marker at the same column in both rows.
        func columns(_ line: String) -> [Int] {
            var result: [Int] = []
            var search = line.startIndex
            while let range = line.range(of: "\\col", range: search..<line.endIndex) {
                result.append(line.distance(from: line.startIndex, to: range.lowerBound))
                search = range.upperBound
            }
            return result
        }
        #expect(columns(lines[2]) == columns(lines[3]))
        #expect(lines[2] == "  { \\tuplet 3/2 { \\col c''8[ \\col s  \\col e'' \\col } \\col r4 \\col }")
        // The letters sit over the cells: c'', s/g', e''/s], r4.
        let row = lines[2]
        let cellStarts = ["c''8[", "s  ", "e''", "r4"].map { row.distance(from: row.startIndex, to: row.range(of: $0)!.lowerBound) }
        let letters = lines[1].enumerated().filter { !" #'()".contains($0.element) }.map(\.offset)
        #expect(letters == cellStarts)
    }

    @Test func tabMovesBetweenCells() throws {
        let text = Self.tidy as NSString
        let start = text.range(of: "c''8[").location
        let next = try #require(TableFormatter.cell(after: start, in: text))
        #expect(text.substring(with: next) == "s")
        let third = try #require(TableFormatter.cell(after: next.location, in: text))
        #expect(text.substring(with: third) == "e''")
        // From the last cell of a row to the first of the next.
        let row2 = try #require(TableFormatter.cell(after: third.location, in: text))
        #expect(text.substring(with: row2) == "s8")
        #expect(TableFormatter.cell(after: text.range(of: "s]").location, in: text) == nil, "the last cell")
        // From the beam row into the first row.
        let fromBeams = try #require(TableFormatter.cell(after: text.range(of: "- )").location, in: text))
        #expect(text.substring(with: fromBeams) == "c''8[")
        let beam = try #require(TableFormatter.cell(after: text.range(of: "#'(").location, in: text))
        #expect(text.substring(with: beam) == "C")
        // Back.
        let back = try #require(TableFormatter.cell(after: text.range(of: "g'").location + 1, backwards: true, in: text))
        #expect(text.substring(with: back) == "s8")
        // An empty cell: the caret after its marker.
        let empty = "\\pianoTable { \\col c4 \\col \\col d4 \\col } { \\col s4 \\col e \\col s4 \\col }" as NSString
        let gap = try #require(TableFormatter.cell(after: empty.range(of: "c4").location, in: empty))
        #expect(gap.length == 0 && empty.substring(with: NSRange(location: gap.location - 5, length: 5)) == "\\col ")
    }

    @Test func addsAndDeletesColumns() throws {
        let text = Self.tidy as NSString
        let add = try #require(TableFormatter.addColumn(at: text.range(of: "c''8[").location, in: text))
        let added = text.replacingCharacters(in: add.range, with: add.replacement)
        #expect(added == """
            music = {
              \\pianoTable
                #'(    C          -    -       - )
                { \\col c''8[ \\col \\col s  \\col e'' \\col }
                { \\col s8    \\col \\col g' \\col s]  \\col }
              r2
            }
            """)
        // The caret is in the new cell of its row.
        #expect((added as NSString).substring(with: NSRange(location: add.selection.location - 5, length: 5)) == "\\col ")
        #expect(add.selection.location == (added as NSString).range(of: "\\col \\col s").location + 5)

        let delete = try #require(TableFormatter.deleteColumn(at: (added as NSString).range(of: "g'").location,
                                                               in: added as NSString))
        let deleted = (added as NSString).replacingCharacters(in: delete.range, with: delete.replacement)
        #expect(deleted == """
            music = {
              \\pianoTable
                #'(    C          -    - )
                { \\col c''8[ \\col \\col e'' \\col }
                { \\col s8    \\col \\col s]  \\col }
              r2
            }
            """)
        // At the end of a row.
        let last = try #require(TableFormatter.addColumn(at: text.range(of: "e''").location, in: text))
        let appended = text.replacingCharacters(in: last.range, with: last.replacement)
        #expect(appended.contains("{ \\col c''8[ \\col s  \\col e'' \\col \\col }"))
        #expect(appended.contains("#'(    C          -       -        - )"))
    }

    @Test func templateAndInclude() throws {
        let (text, cell) = TableFormatter.template(columns: 3, indent: "  ")
        #expect(text == """
            \\pianoTable
                #'(    C       -       - )
                { \\col s8 \\col s8 \\col s8 \\col }
                { \\col s8 \\col s8 \\col s8 \\col }
            """)
        #expect((text as NSString).substring(with: cell) == "s8")
        #expect(TableFormatter.table(containing: 0, in: text as NSString)?.rows.count == 3)

        let score = "\\version \"2.24.0\"\n\\language \"english\"\nmusic = { c4 }\n" as NSString
        let include = try #require(TableFormatter.includeEdit(in: score))
        #expect(score.replacingCharacters(in: include.range, with: include.replacement)
                == "\\version \"2.24.0\"\n\\include \"piano-tables.ily\"\n\\language \"english\"\nmusic = { c4 }\n")
        #expect(TableFormatter.includeEdit(in: "\\include \"../piano-tables.ily\"\n") == nil)
        let bare = try #require(TableFormatter.includeEdit(in: "{ c4 }"))
        #expect(bare.range.location == 0 && bare.replacement == "\\include \"piano-tables.ily\"\n\n")
    }
}
