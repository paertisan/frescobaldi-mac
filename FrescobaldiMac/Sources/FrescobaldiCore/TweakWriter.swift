import Foundation

/// A change to an object's layout, written as plain LilyPond.
public enum Tweak: Equatable, Sendable {
    /// `-\tweak [grob.]property value`, or an override before the note.
    /// `grob` is nil for the object itself.
    case set(property: String, grob: String?, value: TweakValue)
    /// `-\shape`: offsets added to the four control points of piece
    /// `piece` of `pieces`.
    case shape(offsets: [GrobLink.Point], piece: Int, pieces: Int)
    /// `-\offset property value`: added to the current value.
    case offset(property: String, value: TweakValue)
}

public enum TweakValue: Equatable, Sendable {
    case number(Double)
    case pair(Double, Double)

    /// `#1.5`, `#'(1 . -0.5)`.
    public var scheme: String {
        switch self {
        case let .number(value): "#" + TweakWriter.format(value)
        case let .pair(x, y): "#'(\(TweakWriter.format(x)) . \(TweakWriter.format(y)))"
        }
    }
}

/// Writes a `Tweak` into the source as one small replacement: a new
/// `-\tweak` before the event the link points at, or a new value for a
/// tweak of the same property that's already there. Objects without event
/// syntax of their own (automatic beams) get `\once \override` before
/// their note instead.
public enum TweakWriter {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The link's line or column isn't in the text (it changed since
        /// the engrave).
        case locationNotFound
        /// The text at the location doesn't look like the event.
        case unexpectedText(String)
        /// A tweak of this property is there, but its value isn't one this
        /// writer can read (`#(…)` code, a variable).
        case unreadableValue(String)

        public var errorDescription: String? {
            switch self {
            case .locationNotFound:
                "The object's place in the source has changed since the last engrave."
            case let .unexpectedText(text):
                "The source at the object's place doesn't look like it (\(text)). Engrave again and retry."
            case let .unreadableValue(value):
                "The object already has a tweak with a value that can't be adjusted here: \(value)"
            }
        }
    }

    /// The replacement that applies `tweak` to the object `link` points at.
    public static func edit(_ tweak: Tweak, for link: GrobLink, in text: NSString) throws -> TextReplacement {
        // Collision properties of a spanner go on the event that made it.
        var line = link.line, column = link.column
        if case let .set(_, grob?, _) = tweak, grob == link.target,
           let targetLine = link.targetLine, let targetColumn = link.targetColumn {
            line = targetLine
            column = targetColumn
        }
        guard let location = location(line: line, column: column, in: text) else { throw Failure.locationNotFound }
        if link.event == "note-event" {
            return try overrideEdit(tweak, grob: link.grob, before: location, in: text)
        }
        let isMusic = link.event == "tuplet-span-event"
        var scanner = Scanner(text: text, location: location)
        let chain = scanner.chain()
        guard scanner.looksLikeEvent(music: isMusic) else {
            throw Failure.unexpectedText(scanner.preview())
        }
        let prefix = isMusic ? "\\tweak " : "-\\tweak "
        switch tweak {
        case let .set(property, grob, value):
            // A tuplet's \tweak also reaches its number; name the bracket.
            let grob = grob ?? (isMusic ? link.grob : nil)
            if let existing = chain.first(where: { $0.kind == .tweak && $0.matches(property: property, grob: grob, own: link.grob) }) {
                return TextReplacement(range: existing.value, replacement: value.scheme)
            }
            let path = grob.map { "\($0).\(property)" } ?? property
            return TextReplacement(range: NSRange(location: location, length: 0),
                                   replacement: "\(prefix)\(path) \(value.scheme) ")
        case let .shape(offsets, piece, pieces):
            if let existing = chain.first(where: { $0.kind == .shape }) {
                let old = text.substring(with: existing.value)
                guard let lists = shapeOffsets(old) else { throw Failure.unreadableValue(old) }
                return TextReplacement(range: existing.value,
                                       replacement: shapeValue(adding: offsets, piece: piece, pieces: pieces, to: lists))
            }
            return TextReplacement(range: NSRange(location: location, length: 0),
                                   replacement: (isMusic ? "\\shape " : "-\\shape ")
                                       + shapeValue(adding: offsets, piece: piece, pieces: pieces, to: []) + " ")
        case let .offset(property, value):
            if let existing = chain.first(where: { $0.kind == .offset && $0.matches(property: property, grob: nil, own: link.grob) }) {
                let old = text.substring(with: existing.value)
                guard let sum = adding(value, to: old) else { throw Failure.unreadableValue(old) }
                return TextReplacement(range: existing.value, replacement: sum.scheme)
            }
            return TextReplacement(range: NSRange(location: location, length: 0),
                                   replacement: (isMusic ? "\\offset " : "-\\offset ") + "\(property) \(value.scheme) ")
        }
    }

    /// The edited text, for tests and tools.
    public static func apply(_ tweak: Tweak, for link: GrobLink, to text: String) throws -> String {
        let edit = try edit(tweak, for: link, in: text as NSString)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: Overrides

    /// `\once \override Grob.property = value` (or `\once \offset …`) right
    /// before the note at `location`, or before its chord. An override of
    /// the same property already there gets the new value.
    static func overrideEdit(_ tweak: Tweak, grob ownGrob: String, before location: Int,
                             in text: NSString) throws -> TextReplacement {
        let start = chordStart(containing: location, in: text) ?? location
        let lineStart = text.lineRange(for: NSRange(location: start, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: start - lineStart)) as NSString
        func existing(_ pattern: String) -> NSTextCheckingResult? {
            let regex = try? NSRegularExpression(pattern: pattern + #"\s*$"#)
            return regex?.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length))
        }
        let value = #"(#'?\([^()]*\)|#-?[0-9.]+)"#
        switch tweak {
        case let .set(property, grob, newValue):
            let grobPattern = NSRegularExpression.escapedPattern(for: grob ?? ownGrob)
            let name = NSRegularExpression.escapedPattern(for: property)
            if let match = existing(#"\\once\s+\\override\s+(?:[A-Za-z]+\.)?"# + grobPattern + #"\."# + name + #"\s*=\s*"# + value) {
                let range = match.range(at: 1)
                return TextReplacement(range: NSRange(location: lineStart + range.location, length: range.length),
                                       replacement: newValue.scheme)
            }
            return TextReplacement(range: NSRange(location: start, length: 0),
                                   replacement: "\\once \\override \(grob ?? ownGrob).\(property) = \(newValue.scheme) ")
        case let .offset(property, newValue):
            let name = NSRegularExpression.escapedPattern(for: property)
            let grobPattern = NSRegularExpression.escapedPattern(for: ownGrob)
            if let match = existing(#"\\once\s+\\offset\s+"# + name + #"\s+"# + value + #"\s+(?:[A-Za-z]+\.)?"# + grobPattern) {
                let range = match.range(at: 1)
                let old = before.substring(with: range)
                guard let sum = adding(newValue, to: old) else { throw Failure.unreadableValue(old) }
                return TextReplacement(range: NSRange(location: lineStart + range.location, length: range.length),
                                       replacement: sum.scheme)
            }
            return TextReplacement(range: NSRange(location: start, length: 0),
                                   replacement: "\\once \\offset \(property) \(newValue.scheme) \(ownGrob) ")
        case let .shape(offsets, piece, pieces):
            return TextReplacement(range: NSRange(location: start, length: 0),
                                   replacement: "\\once \\shape "
                                       + shapeValue(adding: offsets, piece: piece, pieces: pieces, to: []) + " \(ownGrob) ")
        }
    }

    /// The `<` of the chord around `location`, if it's inside one.
    static func chordStart(containing location: Int, in text: NSString) -> Int? {
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        var opening: Int?
        LilyPondLexer.lex(text, range: NSRange(location: 0, length: NSMaxRange(lineRange))) { token in
            guard token.kind == .delimiter, token.range.location < location, token.range.length == 1 else { return }
            switch text.character(at: token.range.location) {
            case 0x3C: opening = token.range.location // <
            case 0x3E: opening = nil // >
            default: break
            }
        }
        return opening
    }

    // MARK: Values

    /// `2.5`, `-0.25`, `0`: at most two decimals.
    public static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "0" }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `old + value` for a number or a pair written as `#…`.
    static func adding(_ value: TweakValue, to old: String) -> TweakValue? {
        guard let datum = SchemeDatum.parse(old) else { return nil }
        switch (value, datum) {
        case let (.number(a), .number(b)): return .number(a + b)
        case let (.pair(a, b), _):
            guard let pair = datum.numberPair else { return nil }
            return .pair(pair.0 + a, pair.1 + b)
        default: return nil
        }
    }

    /// The offsets of a `\shape` value: one list of four pairs per piece
    /// (`[]` for a piece left alone).
    static func shapeOffsets(_ value: String) -> [[GrobLink.Point]]? {
        guard case let .list(items, nil)? = SchemeDatum.parse(value) else { return nil }
        func points(_ items: [SchemeDatum]) -> [GrobLink.Point]? {
            let pairs = items.compactMap(\.numberPair)
            return pairs.count == items.count ? pairs.map { GrobLink.Point($0.0, $0.1) } : nil
        }
        if items.isEmpty { return [] }
        if let single = points(items) { return [single] }
        var lists: [[GrobLink.Point]] = []
        for item in items {
            guard case let .list(inner, nil) = item, let list = points(inner) else { return nil }
            lists.append(list)
        }
        return lists
    }

    /// A `\shape` value with `offsets` added to piece `piece`.
    static func shapeValue(adding offsets: [GrobLink.Point], piece: Int, pieces: Int,
                           to old: [[GrobLink.Point]]) -> String {
        let count = max(pieces, old.count, 1)
        var lists = old + Array(repeating: [], count: count - old.count)
        let index = min(max(piece, 1), count) - 1
        let current = lists[index].isEmpty ? Array(repeating: GrobLink.Point.zero, count: 4) : lists[index]
        lists[index] = (0..<max(4, current.count)).map { i in
            let a = i < current.count ? current[i] : .zero
            let b = i < offsets.count ? offsets[i] : .zero
            return GrobLink.Point(a.x + b.x, a.y + b.y)
        }
        func list(_ points: [GrobLink.Point]) -> String {
            "(" + points.map { "(\(format($0.x)) . \(format($0.y)))" }.joined(separator: " ") + ")"
        }
        if count == 1 { return "#'" + list(lists[0]) }
        return "#'(" + lists.map { $0.isEmpty ? "()" : list($0) }.joined(separator: " ") + ")"
    }

    /// UTF-16 location of a LilyPond (line, character column) position.
    static func location(line: Int, column: Int, in text: NSString) -> Int? {
        guard let range = TextLines.range(ofLine: line, in: text) else { return nil }
        let lineText = text.substring(with: range)
        guard column <= lineText.unicodeScalars.count else { return nil }
        return range.location + TextLines.utf16Offset(ofScalarColumn: column, in: lineText)
    }
}

// MARK: - Reading the source

/// One `\tweak`, `\shape` or `\offset` before an event.
struct TweakItem {
    enum Kind { case tweak, shape, offset }
    var kind: Kind
    /// `color`, `Accidental.color`, `#'color`; empty for \shape.
    var path: String
    /// The value's range.
    var value: NSRange

    /// Whether this sets `property` of `grob` (nil: the object itself,
    /// whose name is `own`).
    func matches(property: String, grob: String?, own: String) -> Bool {
        var path = path
        if path.hasPrefix("#'") { path.removeFirst(2) }
        let parts = path.split(separator: ".").map(String.init)
        guard let name = parts.last, name == property else { return false }
        let pathGrob = parts.count > 1 && parts[0].first?.isUppercase == true ? parts[0] : nil
        return (pathGrob ?? own) == (grob ?? own)
    }
}

private struct Scanner {
    let text: NSString
    var i: Int

    init(text: NSString, location: Int) {
        self.text = text
        i = location
    }

    func at(_ j: Int) -> unichar { j < text.length ? text.character(at: j) : 0 }

    func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

    mutating func skipSpace() {
        while i < text.length {
            let c = at(i)
            if isSpace(c) {
                i += 1
            } else if c == 0x25 { // % comment to the end of the line
                while i < text.length && at(i) != 0x0A { i += 1 }
            } else {
                return
            }
        }
    }

    /// `\word` at `j`, if the command there is exactly `word`.
    func command(_ word: String, at j: Int) -> Bool {
        let length = (word as NSString).length
        guard at(j) == 0x5C, j + 1 + length <= text.length,
              text.substring(with: NSRange(location: j + 1, length: length)) == word else { return false }
        return !isLetter(at(j + 1 + length)) && at(j + 1 + length) != 0x2D
    }

    /// The tweaks starting at `i`; leaves `i` at the event they apply to.
    mutating func chain() -> [TweakItem] {
        var items: [TweakItem] = []
        while true {
            let start = i
            var j = i
            if [0x2D, 0x5E, 0x5F].contains(at(j)) { // - ^ _
                j += 1
                while isSpace(at(j)) { j += 1 }
            }
            let kind: TweakItem.Kind
            let word: String
            if command("tweak", at: j) { kind = .tweak; word = "tweak" }
            else if command("shape", at: j) { kind = .shape; word = "shape" }
            else if command("offset", at: j) { kind = .offset; word = "offset" }
            else { i = start; return items }
            i = j + 1 + (word as NSString).length
            skipSpace()
            var path = ""
            if kind != .shape {
                guard let range = datum() else { i = start; return items }
                path = text.substring(with: range)
                skipSpace()
            }
            guard let value = datum() else { i = start; return items }
            items.append(TweakItem(kind: kind, path: path, value: value))
            skipSpace()
        }
    }

    /// A tweak's property path or value: `#…`/`$…` Scheme, a number, a
    /// string or a word like `Grob.property`.
    mutating func datum() -> NSRange? {
        let start = i
        let c = at(i)
        if c == 0x23 || c == 0x24 { // # $
            i += 1
            if at(i) == 0x23 { i += 1 } // ##t
            while at(i) == 0x27 || at(i) == 0x60 || at(i) == 0x2C { i += 1 } // ' ` ,
            guard scheme() else { i = start; return nil }
        } else if c == 0x22 {
            guard string() else { i = start; return nil }
        } else {
            while i < text.length, !isSpace(at(i)), ![0x5C, 0x7B, 0x7D, 0x23].contains(at(i)) { i += 1 }
        }
        return i > start ? NSRange(location: start, length: i - start) : nil
    }

    mutating func string() -> Bool {
        i += 1
        while i < text.length {
            let c = at(i)
            if c == 0x5C { i += 2; continue }
            i += 1
            if c == 0x22 { return true }
        }
        return false
    }

    /// One Scheme datum: a list with balanced parentheses, a string or an atom.
    mutating func scheme() -> Bool {
        if at(i) == 0x22 { return string() }
        if at(i) == 0x28 {
            var depth = 0
            while i < text.length {
                let c = at(i)
                if c == 0x22 { guard string() else { return false }; continue }
                if c == 0x3B { while i < text.length && at(i) != 0x0A { i += 1 }; continue }
                i += 1
                if c == 0x28 { depth += 1 }
                if c == 0x29 { depth -= 1; if depth == 0 { return true } }
            }
            return false
        }
        let start = i
        while i < text.length, !isSpace(at(i)), at(i) != 0x28, at(i) != 0x29 { i += 1 }
        return i > start
    }

    /// Whether `i` is at something an event's link can point at: a
    /// post-event (`->`, `\p`, `(`, `~`, `^"text"`, `-1`) or, for tuplets,
    /// music (`\tuplet`).
    func looksLikeEvent(music: Bool) -> Bool {
        var j = i
        let c = at(j)
        if music { return c == 0x5C }
        if [0x2D, 0x5E, 0x5F].contains(c) {
            j += 1
            while isSpace(at(j)) { j += 1 }
            // -> -. -- -+ -! -_ -^ -| -1 -"text" -\markup
            return j < text.length && !isSpace(at(j))
        }
        // \p \< \( \sustainOn ( ) [ ] ~
        return [0x5C, 0x28, 0x29, 0x5B, 0x5D, 0x7E].contains(c)
    }

    func preview() -> String {
        let range = NSRange(location: i, length: min(12, text.length - i))
        let line = text.substring(with: range).split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "end of line" : "“\(line)”"
    }
}

/// Just enough Scheme to read tweak values: numbers, symbols, strings and
/// (dotted) lists.
indirect enum SchemeDatum: Equatable {
    case number(Double)
    case symbol(String)
    case string(String)
    case list([SchemeDatum], SchemeDatum?)

    /// `(a . b)` with two numbers.
    var numberPair: (Double, Double)? {
        if case let .list(items, tail?) = self, items.count == 1,
           case let .number(a) = items[0], case let .number(b) = tail {
            return (a, b)
        }
        return nil
    }

    /// Parses `#'(1 . 2)`, `#2`, `#-0.5`, `'((0 . 0) …)`.
    static func parse(_ source: String) -> SchemeDatum? {
        var chars = Array(source.unicodeScalars)[...]
        while let first = chars.first, "#$'`".unicodeScalars.contains(first) { chars.removeFirst() }
        var reader = Reader(chars: chars)
        guard let datum = reader.read() else { return nil }
        reader.skipSpace()
        return reader.chars.isEmpty ? datum : nil
    }

    private struct Reader {
        var chars: ArraySlice<Unicode.Scalar>

        mutating func skipSpace() {
            while let c = chars.first, c.properties.isWhitespace { chars.removeFirst() }
        }

        mutating func read() -> SchemeDatum? {
            skipSpace()
            guard let c = chars.first else { return nil }
            if c == "'" { chars.removeFirst(); return read() }
            if c == "(" {
                chars.removeFirst()
                var items: [SchemeDatum] = []
                while true {
                    skipSpace()
                    guard let next = chars.first else { return nil }
                    if next == ")" { chars.removeFirst(); return .list(items, nil) }
                    if next == ".", chars.dropFirst().first.map({ $0.properties.isWhitespace }) ?? false {
                        chars.removeFirst()
                        guard !items.isEmpty, let tail = read() else { return nil }
                        skipSpace()
                        guard chars.first == ")" else { return nil }
                        chars.removeFirst()
                        return .list(items, tail)
                    }
                    guard let item = read() else { return nil }
                    items.append(item)
                }
            }
            if c == ")" { return nil }
            if c == "\"" {
                chars.removeFirst()
                var value = ""
                while let next = chars.first {
                    chars.removeFirst()
                    if next == "\"" { return .string(value) }
                    if next == "\\", let escaped = chars.first { chars.removeFirst(); value.unicodeScalars.append(escaped); continue }
                    value.unicodeScalars.append(next)
                }
                return nil
            }
            var atom = ""
            while let next = chars.first, !next.properties.isWhitespace, next != "(", next != ")" {
                atom.unicodeScalars.append(next)
                chars.removeFirst()
            }
            if let number = Double(atom) { return .number(number) }
            return atom.isEmpty ? nil : .symbol(atom)
        }
    }
}
