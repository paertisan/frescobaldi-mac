import Foundation

/// Piano tables (`\pianoTable`, `\pianoTablePoly` from piano-tables.ily) in
/// the source: finding them, lining up their columns, and the editor's
/// column commands. A table's rows are `{ … }` groups with `\col` between
/// the cells, one per line; a `\pianoTable` may start with a beam row
/// `#'(U - C)`, whose letters go over the cells they belong to.
///
///     \pianoTable
///       #'(    C          -       - )
///       { \col c''8[ \col s  \col e'' \col }
///       { \col s8    \col g' \col s]  \col }
public enum TableFormatter {
    public static let marker = "\\col"
    public static let includeFile = "piano-tables.ily"

    public struct Row: Equatable, Sendable {
        /// UTF-16 range of `{ … }` or `#'( … )`.
        public var range: NSRange
        public var isBeams: Bool
    }

    public struct Table: Equatable, Sendable {
        /// From the command to the end of the last row.
        public var range: NSRange
        public var rows: [Row]
    }

    // MARK: Finding tables

    /// The table whose command or rows contain `location`.
    public static func table(containing location: Int, in text: NSString) -> Table? {
        guard location >= 0, location <= text.length else { return nil }
        // The nearest commands before the location, within a few pages.
        let start = max(0, location - 20_000)
        // Through the command's own name, for a location on it.
        var search = NSRange(location: start, length: min(text.length, location + 16) - start)
        while search.length > 0 {
            let found = text.range(of: "\\pianoTable", options: .backwards, range: search)
            guard found.location != NSNotFound else { return nil }
            if let table = parse(at: found.location, in: text),
               table.range.location <= location, location <= NSMaxRange(table.range) {
                return table
            }
            search.length = found.location - search.location
        }
        return nil
    }

    /// Every table in the text, in order.
    public static func tables(in text: NSString) -> [Table] {
        var tables: [Table] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: "\\pianoTable", options: [], range: search)
            guard found.location != NSNotFound else { break }
            var next = NSMaxRange(found)
            if let table = parse(at: found.location, in: text) {
                tables.append(table)
                next = NSMaxRange(table.range)
            }
            search = NSRange(location: next, length: text.length - next)
        }
        return tables
    }

    /// The table whose command starts at `location`.
    static func parse(at location: Int, in text: NSString) -> Table? {
        var scanner = SourceScanner(text: text, i: location)
        guard !scanner.isInComment(location) else { return nil }
        let word = scanner.word()
        guard word == "\\pianoTable" || word == "\\pianoTablePoly" else { return nil }
        var rows: [Row] = []
        if word == "\\pianoTablePoly" {
            scanner.skipSpace()
            if scanner.at() == 0x23 { scanner.i += 1 } // #2
            guard scanner.number() else { return nil }
            scanner.skipSpace()
            guard scanner.at() == 0x7B, let outer = scanner.group() else { return nil }
            var inner = SourceScanner(text: text, i: outer.location + 1)
            while true {
                inner.skipSpace()
                guard inner.i < NSMaxRange(outer) - 1 else { break }
                if inner.at() == 0x7B, let row = inner.group() {
                    rows.append(Row(range: row, isBeams: false))
                } else if inner.musicPrefix(), inner.at() == 0x7B, let row = inner.group() {
                    rows.append(Row(range: row, isBeams: false))
                } else {
                    break
                }
            }
            return rows.isEmpty ? nil : Table(range: NSRange(location: location, length: NSMaxRange(outer) - location),
                                              rows: rows)
        }
        // The beam row comes first (LilyPond can't skip an optional last argument).
        var probe = scanner
        probe.skipSpace()
        if let beams = probe.schemeList() {
            rows.append(Row(range: beams, isBeams: true))
            scanner = probe
        }
        let musicRows = rows.count + 2
        while rows.count < musicRows {
            var probe = scanner
            probe.skipSpace()
            _ = probe.musicPrefix()
            guard probe.at() == 0x7B, let row = probe.group() else { break }
            rows.append(Row(range: row, isBeams: false))
            scanner = probe
        }
        guard !rows.isEmpty else { return nil }
        return Table(range: NSRange(location: location, length: NSMaxRange(rows[rows.count - 1].range) - location),
                     rows: rows)
    }

    // MARK: Lining up

    /// The replacement that lines up the columns of the table around
    /// `location`, and the selection mapped into the new text. Nil if
    /// there's no table or it's already lined up.
    public static func format(at location: Int, in text: NSString, selection: NSRange) -> TextEditing.Edit? {
        guard let table = table(containing: location, in: text),
              let (region, formatted) = formattedRegion(table, in: text) else { return nil }
        let old = text.substring(with: region)
        guard old != formatted else { return nil }
        let mapped = map(selection, from: old, to: formatted, region: region)
        guard let change = TextReplacement.between(old, formatted) else { return nil }
        return TextEditing.Edit(range: NSRange(location: region.location + change.range.location, length: change.range.length),
                                replacement: change.replacement, selection: mapped)
    }

    /// The lines of the table's rows, and their text lined up.
    static func formattedRegion(_ table: Table, in text: NSString) -> (NSRange, String)? {
        let lines = table.rows.map { text.lineRange(for: NSRange(location: $0.range.location, length: 0)) }
        // Each row on a line of its own.
        for (row, line) in zip(table.rows, lines) where NSMaxRange(row.range) > NSMaxRange(line) { return nil }
        guard Set(lines.map(\.location)).count == lines.count else { return nil }
        let parsed = zip(table.rows, lines).map { row, line in ParsedRow(row: row, line: line, text: text) }
        let music = parsed.filter { !$0.isBeams && !$0.markers.isEmpty }
        guard !music.isEmpty else { return nil }

        // Where each beam letter goes: after the marker that starts its cell
        // in the first music row (-1: before the first marker).
        let cells = music[0].cellMarkers
        let markerCount = music.map(\.markers.count).max() ?? 0
        let beams = parsed.first(where: \.isBeams)
        var columns: [Int] = []
        var itemColumns: [Int] = []
        func itemMinimum(_ index: Int) -> Int {
            guard let beams else { return 0 }
            if index == 0 { return beams.lead.count }
            return itemColumns[index - 1] + beams.items[index - 1].count + 1
        }
        // Items in a cell before the first marker.
        if let beams, !beams.items.isEmpty, cells.first == -1 {
            itemColumns.append(max(itemMinimum(0), music[0].leadContentColumn))
        }
        for k in 0..<markerCount {
            var column = 0
            for row in music where row.markers.count > k {
                if k == 0 {
                    column = max(column, row.lead.trimmingTrailingSpace.count + 1)
                } else {
                    let width = row.segments[k - 1].trimmed.count
                    column = max(column, columns[k - 1] + marker.count + 1 + width + (width > 0 ? 1 : 0))
                }
            }
            // A letter wider than its cell pushes the cell's marker.
            if let beams, let item = cells.firstIndex(of: k), item < beams.items.count, item == itemColumns.count {
                column = max(column, itemMinimum(item) - marker.count - 1)
                columns.append(column)
                itemColumns.append(column + marker.count + 1)
            } else {
                columns.append(column)
            }
        }

        // The rows, and their comments lined up after the longest.
        var bodies: [String] = []
        for row in parsed {
            if row.isBeams {
                var body = row.lead
                for (index, item) in row.items.enumerated() {
                    let target = index < itemColumns.count ? itemColumns[index] : body.count + 1
                    body += String(repeating: " ", count: max(index == 0 ? 0 : 1, target - body.count)) + item
                }
                bodies.append(body + " " + row.tailCode)
            } else if row.markers.isEmpty {
                bodies.append(row.lead.trimmingTrailingSpace + row.tailCode)
            } else {
                var body = row.lead.trimmingTrailingSpace
                for k in row.markers.indices {
                    if k > 0 {
                        let content = row.segments[k - 1].trimmed
                        if !content.isEmpty { body += " " + content }
                    }
                    body += String(repeating: " ", count: max(1, columns[k] - body.count)) + marker
                }
                let tail = row.tailCode
                bodies.append(tail.isEmpty ? body : body + " " + tail)
            }
        }
        let commentColumn = (zip(parsed, bodies).filter { !$0.0.comment.isEmpty }.map { $0.1.count }.max() ?? 0) + 2
        var result = ""
        for (index, (row, body)) in zip(parsed, bodies).enumerated() {
            if index > 0 {
                // What's between the rows' lines stays.
                let gap = NSRange(location: NSMaxRange(parsed[index - 1].lineContents),
                                  length: row.line.location - NSMaxRange(parsed[index - 1].lineContents))
                result += text.substring(with: gap)
            }
            result += row.comment.isEmpty ? body : body + String(repeating: " ", count: commentColumn - body.count) + row.comment
        }
        let region = NSRange(location: parsed[0].line.location,
                             length: NSMaxRange(parsed[parsed.count - 1].lineContents) - parsed[0].line.location)
        return (region, result)
    }

    /// Maps a selection across a change that only moved spaces: by the
    /// characters before it that aren't spaces, then the spaces typed after them.
    static func map(_ selection: NSRange, from old: String, to new: String, region: NSRange) -> NSRange {
        let a = Array(old.utf16), b = Array(new.utf16)
        func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
        func mapOffset(_ offset: Int) -> Int {
            let offset = min(max(0, offset), a.count)
            var solid = 0, spaces = 0
            for u in a[0..<offset] {
                if isSpace(u) { spaces += 1 } else { solid += 1; spaces = 0 }
            }
            var j = 0, seen = 0
            while j < b.count && seen < solid {
                if !isSpace(b[j]) { seen += 1 }
                j += 1
            }
            var run = 0
            while j + run < b.count && isSpace(b[j + run]) { run += 1 }
            return j + min(spaces, run)
        }
        let start = selection.location - region.location
        let end = NSMaxRange(selection) - region.location
        guard start >= 0, end <= a.count else {
            // Outside the region: shift what comes after it.
            if selection.location >= NSMaxRange(region) {
                return NSRange(location: selection.location + b.count - a.count, length: selection.length)
            }
            return selection
        }
        let newStart = mapOffset(start)
        let newEnd = selection.length == 0 ? newStart : mapOffset(end)
        return NSRange(location: region.location + newStart, length: max(0, newEnd - newStart))
    }

    // MARK: Moving between cells

    /// Where Tab (or ⇧Tab) goes from `location`: the next (previous) cell's
    /// contents, selected, in this row or the next (previous) one.
    public static func cell(after location: Int, backwards: Bool = false, in text: NSString) -> NSRange? {
        guard location >= 0, location <= text.length else { return nil }
        guard let table = table(containing: location, in: text) else { return nil }
        let cells = cellRanges(table, in: text)
        if backwards {
            // The start of the cell the location is in, then the one before.
            let current = cells.last { $0.location <= location } ?? cells.first
            return cells.last { $0.location < (current?.location ?? location) }
        }
        return cells.first { $0.location > location }
    }

    /// The contents of every cell (without the spaces around them), row by
    /// row; an empty cell is an empty range after its marker's space.
    static func cellRanges(_ table: Table, in text: NSString) -> [NSRange] {
        var cells: [NSRange] = []
        for row in table.rows {
            let line = text.lineRange(for: NSRange(location: row.range.location, length: 0))
            let parsed = ParsedRow(row: row, line: line, text: text)
            cells += parsed.cellRanges
        }
        return cells
    }

    // MARK: Columns

    /// A new empty column after the one at `location`, in every row; the
    /// selection goes into it.
    public static func addColumn(at location: Int, in text: NSString) -> TextEditing.Edit? {
        columnEdit(at: location, in: text, adding: true)
    }

    /// Removes the column at `location` from every row.
    public static func deleteColumn(at location: Int, in text: NSString) -> TextEditing.Edit? {
        columnEdit(at: location, in: text, adding: false)
    }

    private static func columnEdit(at location: Int, in text: NSString, adding: Bool) -> TextEditing.Edit? {
        guard let table = table(containing: location, in: text) else { return nil }
        let parsed = parsedRows(table, in: text)
        guard let reference = parsed.first(where: { !$0.isBeams && !$0.markers.isEmpty }) else { return nil }
        let rowIndex = parsed.firstIndex { NSLocationInRange(location, $0.line) || location == NSMaxRange($0.lineContents) }
            ?? 0
        let here = parsed[rowIndex]
        // The column: the marker before the location (-1: before the first).
        let k = here.isBeams ? here.markerIndex(before: location, beamsRow: here, reference: reference)
            : here.markerIndex(before: location, beamsRow: nil, reference: reference)
        guard adding ? k >= 0 : k >= 0 else { return nil }
        var edits: [(range: NSRange, text: String)] = []
        for row in parsed {
            if row.isBeams {
                guard let item = reference.cellMarkers.firstIndex(of: k) else { continue }
                if adding {
                    if item + 1 < row.itemRanges.count {
                        edits.append((NSRange(location: row.itemRanges[item + 1].location, length: 0), "- "))
                    } else if let last = row.itemRanges.last {
                        edits.append((NSRange(location: NSMaxRange(last), length: 0), " -"))
                    }
                } else if item < row.itemRanges.count {
                    edits.append((row.itemRanges[item], ""))
                }
            } else if row.markers.count > k {
                let closing = NSMaxRange(row.row.range) - 1
                if adding {
                    edits.append(k + 1 < row.markers.count
                                 ? (NSRange(location: row.markers[k + 1], length: 0), marker + " ")
                                 : (NSRange(location: closing, length: 0), marker + " "))
                } else {
                    let end = k + 1 < row.markers.count ? row.markers[k + 1] : closing
                    edits.append((NSRange(location: row.markers[k], length: end - row.markers[k]), ""))
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        let changed = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            changed.replaceCharacters(in: edit.range, with: edit.text)
        }
        // Line up again; the command didn't move.
        if let newTable = parse(at: table.range.location, in: changed),
           let format = format(at: newTable.range.location, in: changed, selection: NSRange(location: 0, length: 0)) {
            changed.replaceCharacters(in: format.range, with: format.replacement)
        }
        // The selection: the new (or next) cell in the cursor's row.
        var selection = NSRange(location: location, length: 0)
        if let newTable = parse(at: table.range.location, in: changed), rowIndex < newTable.rows.count {
            let row = parsedRows(newTable, in: changed)[rowIndex]
            if row.isBeams {
                let items = row.itemRanges
                let index = min(max(0, (reference.cellMarkers.firstIndex(of: k) ?? 0) + (adding ? 1 : 0)), items.count - 1)
                if index >= 0 && index < items.count { selection = items[index] }
            } else if !row.markers.isEmpty {
                let index = min(adding ? k + 1 : max(0, k), row.markers.count - 1)
                let after = row.markers[index] + (marker as NSString).length
                selection = NSRange(location: min(after + 1, changed.length), length: 0)
                if let cell = row.cellRanges.first(where: { $0.location > row.markers[index] }), !adding {
                    selection = cell
                }
            }
        }
        let first = parsed[0].line.location
        let oldEnd = NSMaxRange(parsed[parsed.count - 1].lineContents)
        let newEnd = oldEnd + changed.length - text.length
        let old = text.substring(with: NSRange(location: first, length: oldEnd - first))
        let new = changed.substring(with: NSRange(location: first, length: newEnd - first))
        guard let change = TextReplacement.between(old, new) else { return nil }
        return TextEditing.Edit(range: NSRange(location: first + change.range.location, length: change.range.length),
                                replacement: change.replacement, selection: selection)
    }

    private static func parsedRows(_ table: Table, in text: NSString) -> [ParsedRow] {
        table.rows.map { ParsedRow(row: $0, line: text.lineRange(for: NSRange(location: $0.range.location, length: 0)),
                                   text: text) }
    }

    // MARK: Inserting

    /// A new table with `columns` columns of skips (`cell`), indented like
    /// `indent`, and the range of its first cell (to select).
    public static func template(columns: Int = 4, cell: String = "s8", indent: String = "")
        -> (text: String, firstCell: NSRange) {
        let count = max(1, columns)
        let row = "{ " + Array(repeating: marker + " " + cell, count: count).joined(separator: " ") + " " + marker + " }"
        let beams = "#'(" + Array(repeating: "-", count: count).enumerated().map { $0.offset == 0 ? "C" : $0.element }
            .joined(separator: " ") + ")"
        let raw = "\\pianoTable\n\(indent)  \(beams)\n\(indent)  \(row)\n\(indent)  \(row)"
        let text = raw as NSString
        if let table = parse(at: 0, in: text), let (region, formatted) = formattedRegion(table, in: text) {
            let result = text.replacingCharacters(in: region, with: formatted) as NSString
            let first = result.range(of: marker + " ")
            return (result as String, NSRange(location: NSMaxRange(first), length: (cell as NSString).length))
        }
        return (raw, NSRange(location: (raw as NSString).range(of: cell).location, length: (cell as NSString).length))
    }

    /// `\include "piano-tables.ily"` after the `\version` line (or at the
    /// top), if the text doesn't include it yet.
    public static func includeEdit(in text: NSString) -> TextReplacement? {
        let pattern = #"\\include\s+"(?:[^"]*/)?piano-tables\.ily""#
        if text.range(of: pattern, options: .regularExpression).location != NSNotFound { return nil }
        let line = "\\include \"\(includeFile)\"\n"
        let version = text.range(of: #"(?m)^\\version\s+"[^"]*"[^\n]*\n?"#, options: .regularExpression)
        if version.location != NSNotFound {
            let end = NSMaxRange(version)
            let needsBreak = end == text.length && !text.substring(with: version).hasSuffix("\n")
            return TextReplacement(range: NSRange(location: end, length: 0), replacement: (needsBreak ? "\n" : "") + line)
        }
        return TextReplacement(range: NSRange(location: 0, length: 0), replacement: line + "\n")
    }
}

// MARK: - Rows as text

private struct ParsedRow {
    let row: TableFormatter.Row
    let line: NSRange
    let text: NSString
    /// The line without its line break.
    let lineContents: NSRange
    /// Locations of the markers (music rows).
    var markers: [Int] = []
    /// Line start to the first marker (music) or through `#'(` (beams).
    var lead = ""
    /// Between consecutive markers.
    var segments: [String] = []
    /// After the last marker or the last item, without a comment.
    var tailCode = ""
    var comment = ""
    /// Beam letters and where they are.
    var items: [String] = []
    var itemRanges: [NSRange] = []

    var isBeams: Bool { row.isBeams }

    init(row: TableFormatter.Row, line: NSRange, text: NSString) {
        self.row = row
        self.line = line
        self.text = text
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        lineContents = NSRange(location: line.location, length: end - line.location)
        let rowEnd = NSMaxRange(row.range)
        let after = text.substring(with: NSRange(location: rowEnd, length: end - rowEnd))
        let (code, comment) = Self.splitComment(after)
        self.comment = comment
        if row.isBeams {
            let open = text.range(of: "(", options: [], range: row.range)
            lead = text.substring(with: NSRange(location: line.location, length: NSMaxRange(open) - line.location))
            var i = NSMaxRange(open)
            let close = rowEnd - 1
            while i < close {
                while i < close, Self.isSpace(text.character(at: i)) { i += 1 }
                let start = i
                while i < close, !Self.isSpace(text.character(at: i)) { i += 1 }
                if i > start {
                    itemRanges.append(NSRange(location: start, length: i - start))
                    items.append(text.substring(with: NSRange(location: start, length: i - start)))
                }
            }
            tailCode = (")" + code).trimmingCharacters(in: .whitespaces)
        } else {
            markers = Self.markerLocations(in: row.range, text: text)
            guard let first = markers.first else {
                lead = text.substring(with: NSRange(location: line.location, length: rowEnd - line.location))
                tailCode = code.trimmingCharacters(in: .whitespaces)
                return
            }
            lead = text.substring(with: NSRange(location: line.location, length: first - line.location))
            for (a, b) in zip(markers, markers.dropFirst()) {
                let start = a + (TableFormatter.marker as NSString).length
                segments.append(text.substring(with: NSRange(location: start, length: b - start)))
            }
            let last = markers[markers.count - 1] + (TableFormatter.marker as NSString).length
            tailCode = (text.substring(with: NSRange(location: last, length: rowEnd - last)) + code)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    /// `\col` outside strings and comments, not the start of a longer word.
    static func markerLocations(in range: NSRange, text: NSString) -> [Int] {
        var result: [Int] = []
        var i = range.location
        let end = NSMaxRange(range)
        let length = (TableFormatter.marker as NSString).length
        while i < end {
            let c = text.character(at: i)
            if c == 0x22 { // string
                i += 1
                while i < end, text.character(at: i) != 0x22 {
                    if text.character(at: i) == 0x5C { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == 0x25 { break } // comment to the end of the line
            if c == 0x5C, i + length <= end, text.substring(with: NSRange(location: i, length: length)) == TableFormatter.marker {
                let next = i + length < text.length ? text.character(at: i + length) : 0x20
                let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A) || next == 0x2D || next == 0x5F
                if !isLetter {
                    result.append(i)
                    i += length
                    continue
                }
            }
            i += 1
        }
        return result
    }

    static func splitComment(_ text: String) -> (code: String, comment: String) {
        var inString = false
        var previous: Character = " "
        for index in text.indices {
            let c = text[index]
            if c == "\"" && previous != "\\" { inString.toggle() }
            if c == "%" && !inString {
                return (String(text[..<index]), String(text[index...]).trimmingCharacters(in: .whitespaces))
            }
            previous = c
        }
        return (text, "")
    }

    /// Text that only opens or closes groups and tuplets: not a cell.
    static func isStructural(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(
            of: #"\\(?:tuplet|times|tupletUp|tupletDown|tupletNeutral|relative|fixed|absolute)\b[^{}\\]*"#,
            with: "", options: .regularExpression)
        return !stripped.isEmpty && stripped.allSatisfy { $0 == "{" || $0 == "}" || $0 == " " || $0 == "\t" }
            && stripped.contains(where: { $0 == "{" || $0 == "}" })
    }

    /// For each cell of the row, the marker it follows (-1 before the
    /// first), as the table's Scheme reads them.
    var cellMarkers: [Int] {
        var result: [Int] = []
        let leadContent = Self.leadContent(lead)
        if !leadContent.trimmed.isEmpty && !Self.isStructural(leadContent) { result.append(-1) }
        for (k, segment) in segments.enumerated() where !Self.isStructural(segment) {
            result.append(k)
        }
        let tail = tailCode.hasSuffix("}") ? String(tailCode.dropLast()) : tailCode
        if !tail.trimmed.isEmpty && !Self.isStructural(tail), !markers.isEmpty { result.append(markers.count - 1) }
        return result
    }

    /// The lead after the row's opening `{` (and a \relative before it).
    static func leadContent(_ lead: String) -> String {
        guard let brace = lead.firstIndex(of: "{") else { return "" }
        return String(lead[lead.index(after: brace)...])
    }

    /// Where a cell before the first marker starts.
    var leadContentColumn: Int {
        guard let brace = lead.firstIndex(of: "{") else { return lead.count }
        return lead.distance(from: lead.startIndex, to: brace) + 2
    }

    /// The marker before `location`: -1 before the first. In the beam row,
    /// the marker of the reference row's cell whose letter it is.
    func markerIndex(before location: Int, beamsRow: ParsedRow?, reference: ParsedRow) -> Int {
        if let beamsRow {
            let item = beamsRow.itemRanges.lastIndex { $0.location <= location } ?? 0
            let cells = reference.cellMarkers
            return item < cells.count ? cells[item] : (cells.last ?? -1)
        }
        return (markers.lastIndex { $0 < location }).map { $0 } ?? -1
    }

    /// The contents of the row's cells, as `TableFormatter.cell(after:)`
    /// visits them.
    var cellRanges: [NSRange] {
        if isBeams { return itemRanges }
        var result: [NSRange] = []
        let markerLength = (TableFormatter.marker as NSString).length
        for (k, location) in markers.enumerated() {
            let start = location + markerLength
            let end = k + 1 < markers.count ? markers[k + 1] : NSMaxRange(row.range) - 1
            guard end > start else { continue }
            let segment = text.substring(with: NSRange(location: start, length: end - start))
            if k + 1 >= markers.count && segment.trimmed.isEmpty { continue }
            if Self.isStructural(segment) { continue }
            var a = start, b = end
            while a < b, Self.isSpace(text.character(at: a)) { a += 1 }
            while b > a, Self.isSpace(text.character(at: b - 1)) { b -= 1 }
            if a == b { a = min(start + 1, end) ; b = a }
            result.append(NSRange(location: a, length: b - a))
        }
        return result
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
    var trimmingTrailingSpace: String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
}

/// Just enough of LilyPond to find a table's rows: words, numbers, braced
/// groups and Scheme lists, skipping comments and strings.
private struct SourceScanner {
    let text: NSString
    var i: Int

    func at(_ j: Int? = nil) -> unichar {
        let k = j ?? i
        return k < text.length ? text.character(at: k) : 0
    }

    func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

    /// Whether `location` is after a `%` on its line (outside strings).
    func isInComment(_ location: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        var inString = false
        var j = line.location
        while j < location {
            let c = text.character(at: j)
            if c == 0x5C && inString { j += 2; continue }
            if c == 0x22 { inString.toggle() }
            if c == 0x25 && !inString { return true }
            j += 1
        }
        return false
    }

    mutating func skipSpace() {
        while i < text.length {
            let c = at()
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else if c == 0x25 {
                if at(i + 1) == 0x7B { // %{ … %}
                    let end = text.range(of: "%}", options: [], range: NSRange(location: i + 2, length: text.length - i - 2))
                    i = end.location == NSNotFound ? text.length : NSMaxRange(end)
                } else {
                    while i < text.length && at() != 0x0A { i += 1 }
                }
            } else {
                return
            }
        }
    }

    /// `\word` at i.
    mutating func word() -> String {
        guard at() == 0x5C else { return "" }
        let start = i
        i += 1
        while isLetter(at()) { i += 1 }
        return text.substring(with: NSRange(location: start, length: i - start))
    }

    mutating func number() -> Bool {
        let start = i
        while at() >= 0x30 && at() <= 0x39 { i += 1 }
        return i > start
    }

    /// `\relative c'`, `\fixed c'`, `\absolute` before a row's `{`.
    mutating func musicPrefix() -> Bool {
        let start = i
        let command = word()
        guard ["\\relative", "\\fixed", "\\absolute"].contains(command) else { i = start; return false }
        skipSpace()
        while i < text.length, at() != 0x7B, at() != 0x0A, at() != 0x20 { i += 1 } // the pitch
        skipSpace()
        return true
    }

    /// The `{ … }` at i, through its closing brace.
    mutating func group() -> NSRange? {
        guard at() == 0x7B else { return nil }
        let start = i
        var depth = 0
        while i < text.length {
            let c = at()
            if c == 0x22 {
                i += 1
                while i < text.length, at() != 0x22 { if at() == 0x5C { i += 1 }; i += 1 }
                i += 1
                continue
            }
            if c == 0x25 { skipSpace(); continue }
            i += 1
            if c == 0x7B { depth += 1 }
            if c == 0x7D {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: i - start) }
            }
        }
        i = start
        return nil
    }

    /// `#'( … )` at i.
    mutating func schemeList() -> NSRange? {
        let start = i
        guard at() == 0x23 else { return nil }
        i += 1
        if at() == 0x27 || at() == 0x60 { i += 1 }
        guard at() == 0x28 else { i = start; return nil }
        var depth = 0
        while i < text.length {
            let c = at()
            i += 1
            if c == 0x28 { depth += 1 }
            if c == 0x29 {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: i - start) }
            }
            if c == 0x0A { break }
        }
        i = start
        return nil
    }
}
