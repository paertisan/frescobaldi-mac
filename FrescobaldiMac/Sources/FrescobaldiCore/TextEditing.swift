import Foundation

/// Editor operations on LilyPond source, independent of the text view.
/// Each returns a replacement for the old text and the selection to set
/// afterwards (in the new text).
public enum TextEditing {
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange
    }

    /// Range of all lines touched by `selection` (a selection ending right at
    /// a line start doesn't include that line), without the final line break.
    public static func lineBlock(for selection: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0 && end > selection.location && end <= text.length && end > 0 {
            let previous = text.character(at: end - 1)
            if previous == 0x0A || previous == 0x0D { end -= 1 }
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(end, selection.location), length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: last.location, length: 0))
        return NSRange(location: first.location, length: contentsEnd - first.location)
    }

    /// ⌘/: comment out the lines with `% ` or, if every non-blank line is
    /// already commented, uncomment them.
    public static func toggleComment(selection: NSRange, in text: NSString) -> Edit {
        let block = lineBlock(for: selection, in: text)
        let lines = text.substring(with: block).components(separatedBy: "\n")
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let uncomment = !nonBlank.isEmpty && nonBlank.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("%")
        }
        // Comment at the smallest indentation so the block stays aligned.
        let indent = nonBlank.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let newLines = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if uncomment {
                guard let percent = line.firstIndex(of: "%") else { return line }
                var after = line.index(after: percent)
                if after < line.endIndex && line[after] == " " { after = line.index(after: after) }
                return String(line[..<percent]) + String(line[after...])
            }
            let index = line.index(line.startIndex, offsetBy: indent)
            return String(line[..<index]) + "% " + String(line[index...])
        }
        let replacement = newLines.joined(separator: "\n")
        return Edit(range: block, replacement: replacement,
                    selection: NSRange(location: block.location, length: (replacement as NSString).length))
    }

    /// ⌘] / ⌘[: indent or outdent the lines by `width` spaces (a leading tab
    /// counts as one level).
    public static func shift(selection: NSRange, in text: NSString, right: Bool, width: Int = 2) -> Edit {
        let block = lineBlock(for: selection, in: text)
        let lines = text.substring(with: block).components(separatedBy: "\n")
        let unit = String(repeating: " ", count: width)
        let newLines = lines.map { line -> String in
            if right { return line.isEmpty ? line : unit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = min(width, line.prefix { $0 == " " }.count)
            return String(line.dropFirst(spaces))
        }
        let replacement = newLines.joined(separator: "\n")
        return Edit(range: block, replacement: replacement,
                    selection: NSRange(location: block.location, length: (replacement as NSString).length))
    }

    /// The text to insert for Return at `location`: a line break plus the
    /// current line's indentation, one level deeper after an opening `{` or `<<`.
    public static func newlineInsertion(at location: Int, in text: NSString, width: Int = 2) -> String {
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        // Ignore a trailing comment when looking for an opening bracket.
        var code = before
        if let percent = code.firstIndex(of: "%") { code = String(code[..<percent]) }
        code = code.trimmingCharacters(in: .whitespaces)
        let opens = code.hasSuffix("{") || code.hasSuffix("<<")
        return "\n" + indent + (opens ? String(repeating: " ", count: width) : "")
    }

    /// When typing `}` or `>>` on a line containing only whitespace, the
    /// edit that removes one indentation level first. Nil if nothing to do.
    public static func dedentForClosing(at location: Int, in text: NSString, width: Int = 2) -> Edit? {
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        guard !before.isEmpty, before.allSatisfy({ $0 == " " }) else { return nil }
        let remove = min(width, before.count)
        return Edit(range: NSRange(location: location - remove, length: remove), replacement: "",
                    selection: NSRange(location: location - remove, length: 0))
    }
}

/// A find-and-replace edit that must match exactly once, as used by AI
/// tools: they name the text to change instead of counting lines and columns.
public struct TextSubstitution: Equatable, Sendable {
    public var old: String
    public var new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case empty(index: Int)
        case notFound(index: Int)
        case ambiguous(index: Int, count: Int)

        public var errorDescription: String? {
            switch self {
            case let .empty(index): "Edit \(index + 1): old_text is empty."
            case let .notFound(index): "Edit \(index + 1): old_text wasn't found in the document."
            case let .ambiguous(index, count):
                "Edit \(index + 1): old_text occurs \(count) times; include more surrounding text so it's unique."
            }
        }
    }

    /// Applies `substitutions` in order, each to the result of the previous
    /// one. Nothing is applied unless all of them match exactly once.
    public static func apply(_ substitutions: [TextSubstitution], to text: String) throws -> String {
        var result = text as NSString
        for (index, substitution) in substitutions.enumerated() {
            guard !substitution.old.isEmpty else { throw Failure.empty(index: index) }
            let first = result.range(of: substitution.old)
            guard first.location != NSNotFound else { throw Failure.notFound(index: index) }
            var count = 1
            var search = NSRange(location: first.location + 1, length: result.length - first.location - 1)
            while search.length > 0 {
                let next = result.range(of: substitution.old, options: [], range: search)
                if next.location == NSNotFound { break }
                count += 1
                search = NSRange(location: next.location + 1, length: result.length - next.location - 1)
            }
            guard count == 1 else { throw Failure.ambiguous(index: index, count: count) }
            result = result.replacingCharacters(in: first, with: substitution.new) as NSString
        }
        return result as String
    }
}
