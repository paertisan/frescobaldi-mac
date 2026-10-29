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
