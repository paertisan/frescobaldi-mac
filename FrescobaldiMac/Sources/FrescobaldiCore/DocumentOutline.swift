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
