import Foundation

/// An entry in the document outline sidebar.
public struct OutlineItem: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case assignment, score, header, book, bookpart, paper, layout, midi, include, version, marker
    }

    public var kind: Kind
    /// What to show: the variable name, included file, version, marker text,
    /// or the keyword (`\score`).
    public var title: String
    /// Range of the item's first token in the text.
    public var range: NSRange
    /// 1-based line.
    public var line: Int
    /// Nesting depth: 0 for top level, 1 for `\header` inside `\score`, ...
    public var level: Int

    /// Position in the text identifies an item well enough between updates.
    public var id: String { "\(kind.rawValue):\(range.location):\(title)" }

    public init(kind: Kind, title: String, range: NSRange, line: Int, level: Int) {
        self.kind = kind
        self.title = title
        self.range = range
        self.line = line
        self.level = level
    }
}

/// Builds the outline: top-level assignments (`melody = ...`), the block
/// structure (`\book`, `\bookpart`, `\score`, `\header`, `\paper`, `\layout`,
/// `\midi`) outside music, `\include`, `\version`, and `%%` marker comments.
public enum DocumentOutline {
    private static let blockKinds: [String: OutlineItem.Kind] = [
        "\\score": .score, "\\header": .header, "\\book": .book, "\\bookpart": .bookpart,
        "\\paper": .paper, "\\layout": .layout, "\\midi": .midi,
    ]
    /// Blocks whose contents still belong in the outline.
    private static let structuralKinds: Set<OutlineItem.Kind> = [.book, .bookpart, .score]

    public static func items(in text: NSString) -> [OutlineItem] {
        var tokens: [LilyToken] = []
        LilyPondLexer.lex(text, range: NSRange(location: 0, length: text.length)) { tokens.append($0) }

        // Line starts for cheap line numbers.
        var lineStarts = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }
        func line(of location: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        var items: [OutlineItem] = []
        /// One entry per open `{`/`<<`: the block's kind, or nil for music etc.
        var stack: [OutlineItem.Kind?] = []
        var pendingBlock: OutlineItem.Kind?
        var pendingString: (kind: OutlineItem.Kind, index: Int)?

        var visible: Bool { stack.allSatisfy { $0.map(structuralKinds.contains) ?? false } }

        for token in tokens {
            let word = text.substring(with: token.range)
            if let p = pendingString, token.kind != .comment {
                if token.kind == .string {
                    let unquoted = word.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !unquoted.isEmpty { items[p.index].title = unquoted }
                }
                pendingString = nil
            }
            switch token.kind {
            case .comment where word.hasPrefix("%%"):
                let title = word.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    items.append(.init(kind: .marker, title: title, range: token.range,
                                       line: line(of: token.range.location), level: stack.count))
                }
            case .variable where !word.hasPrefix("\\"):
                // The lexer only marks `name =` as a variable at top level.
                items.append(.init(kind: .assignment, title: word, range: token.range,
                                   line: line(of: token.range.location), level: 0))
            case .keyword:
                if let kind = blockKinds[word] {
                    pendingBlock = kind
                    if visible {
                        items.append(.init(kind: kind, title: word, range: token.range,
                                           line: line(of: token.range.location), level: stack.count))
                    }
                } else if word == "\\include" || word == "\\version" {
                    let kind: OutlineItem.Kind = word == "\\include" ? .include : .version
                    items.append(.init(kind: kind, title: word, range: token.range,
                                       line: line(of: token.range.location), level: stack.count))
                    pendingString = (kind, items.count - 1)
                } else {
                    pendingBlock = nil
                }
            case .delimiter where word == "{" || word == "<<":
                stack.append(pendingBlock)
                pendingBlock = nil
            case .delimiter where word == "}" || word == ">>":
                if !stack.isEmpty { stack.removeLast() }
                pendingBlock = nil
            case .comment:
                break
            default:
                pendingBlock = nil
            }
        }
        return items
    }
}

/// What a file does at top level: whether LilyPond makes output from it,
/// and what it includes.
public struct TopLevelSummary: Equatable, Sendable {
    public struct Include: Equatable, Sendable {
        /// The path as written.
        public var path: String
        /// 1-based line of the `\include`.
        public var line: Int
        /// At top level or directly in a `\book`/`\bookpart`, where the
        /// included file's scores become part of the output. Includes inside
        /// a `\score`, an assignment or `\header` only bring in content.
        public var isSection: Bool
    }

    /// The file has a top-level `\score`, `\book`, `\bookpart`, `\markup`,
    /// `\markuplist` or music (LilyPond's implicit score), not counting what
    /// its includes add.
    public var producesOutput: Bool
    public var includes: [Include]
}

extension DocumentOutline {
    private enum Block { case book, bookpart, score, settings, music, value }

    /// Words that start music at top level, where LilyPond wraps them in an
    /// implicit `\score`.
    private static let musicStarters: Set<String> = [
        "\\new", "\\context", "\\relative", "\\fixed", "\\absolute", "\\transpose", "\\simultaneous",
        "\\sequential", "\\chordmode", "\\chords", "\\drummode", "\\drums", "\\figuremode", "\\figures",
        "\\lyricmode", "\\lyrics", "\\notemode", "\\repeat", "\\partCombine", "\\unfoldRepeats", "\\articulate",
        "\\keepWithTag", "\\removeWithTag", "\\tag", "\\addlyrics", "\\lyricsto", "\\autoChange",
        "\\compressMMRests", "\\compressEmptyMeasures",
    ]
    private static let outputKeywords: Set<String> = ["\\score", "\\book", "\\bookpart", "\\markup", "\\markuplist"]
    private static let blockKeywords: [String: Block] = [
        "\\book": .book, "\\bookpart": .bookpart, "\\score": .score,
        "\\header": .settings, "\\paper": .settings, "\\layout": .settings, "\\midi": .settings, "\\with": .settings,
    ]

    /// A rough reading of the top level: good enough to tell scores from
    /// include files, and errs towards "makes output".
    ///
    /// An assignment's value runs until the next line that starts in column 0
    /// outside braces, which is how LilyPond files are written in practice.
    public static func topLevel(in text: NSString) -> TopLevelSummary {
        var tokens: [LilyToken] = []
        LilyPondLexer.lex(text, range: NSRange(location: 0, length: text.length)) {
            if $0.kind != .comment { tokens.append($0) }
        }
        var lineStarts = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A { lineStarts.append(i + 1) }
        func line(of location: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }
        func startsLine(_ location: Int) -> Bool { location == 0 || text.character(at: location - 1) == 0x0A }

        var output = false
        var includes: [TopLevelSummary.Include] = []
        var stack: [Block] = []
        var pendingBlock: Block?
        var pendingInclude: (line: Int, isSection: Bool)?
        var inAssignment = false
        var assignmentTokens = 0

        for token in tokens {
            let word = text.substring(with: token.range)
            if let include = pendingInclude {
                pendingInclude = nil
                if token.kind == .string {
                    let path = word.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !path.isEmpty { includes.append(.init(path: path, line: include.line, isSection: include.isSection)) }
                    continue
                }
            }
            if stack.isEmpty && inAssignment && assignmentTokens > 0 && startsLine(token.range.location) {
                inAssignment = false
            }
            let atTop = stack.isEmpty && !inAssignment
            let isValueToken = stack.isEmpty && inAssignment
            let inSection = !inAssignment && stack.allSatisfy { $0 == .book || $0 == .bookpart }

            switch token.kind {
            case .keyword where word == "\\include":
                pendingInclude = (line(of: token.range.location), inSection)
            case .variable where !word.hasPrefix("\\") && stack.isEmpty:
                inAssignment = true
                assignmentTokens = 0
                continue
            case .delimiter where word == "{" || word == "<<":
                if atTop && pendingBlock == nil { output = true }
                stack.append(pendingBlock ?? (stack.isEmpty && inAssignment ? .value : .music))
                pendingBlock = nil
            case .delimiter where word == "}" || word == ">>":
                if !stack.isEmpty { stack.removeLast() }
                pendingBlock = nil
            case .delimiter where word == "=" && stack.isEmpty && inAssignment && assignmentTokens == 0:
                continue
            default:
                if let block = blockKeywords[word] {
                    pendingBlock = block
                } else {
                    pendingBlock = nil
                }
                if atTop {
                    if outputKeywords.contains(word) || musicStarters.contains(word) { output = true }
                    switch token.kind {
                    case .pitch, .rest: output = true
                    // A user variable on its own at top level is music, as in `\melody`.
                    case .variable where word.hasPrefix("\\"): output = true
                    default: break
                    }
                }
            }
            if isValueToken { assignmentTokens += 1 }
        }
        return TopLevelSummary(producesOutput: output, includes: includes)
    }
}
