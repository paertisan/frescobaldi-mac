import Foundation

/// A LilyPond point-and-click link: `textedit:///abs/path.ly:LINE:START:END`.
///
/// LilyPond writes one per notated object when run with `-dpoint-and-click`.
/// PDFKit exposes them as `PDFAnnotation.url`. LINE is 1-based; START and END
/// are 0-based character (Unicode scalar) columns. The path is percent-encoded.
public struct TextEditLink: Equatable, Hashable, Sendable {
    public var path: String
    /// 1-based line number.
    public var line: Int
    /// 0-based character column where the object starts.
    public var startColumn: Int
    /// 0-based character column where the object ends (exclusive).
    public var endColumn: Int

    public init(path: String, line: Int, startColumn: Int, endColumn: Int) {
        self.path = path
        self.line = line
        self.startColumn = startColumn
        self.endColumn = endColumn
    }

    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    /// Parses `textedit://` links. Also accepts the older two-number form
    /// `path:LINE:COLUMN`, in which case the range is empty.
    public init?(string: String) {
        let prefix = "textedit://"
        guard string.count > prefix.count,
              string.prefix(prefix.count).lowercased() == prefix else { return nil }
        var rest = String(string.dropFirst(prefix.count))
        rest = rest.removingPercentEncoding ?? rest

        // Paths may contain colons, so take the numbers from the end.
        var numbers: [Int] = []
        while numbers.count < 3, let colon = rest.lastIndex(of: ":") {
            guard let value = Int(rest[rest.index(after: colon)...]), value >= 0 else { break }
            numbers.insert(value, at: 0)
            rest = String(rest[..<colon])
        }
        guard numbers.count >= 2, !rest.isEmpty, numbers[0] >= 1 else { return nil }
        // `textedit://localhost/path` → `/path`
        if rest.hasPrefix("localhost/") { rest.removeFirst("localhost".count) }
        self.path = rest
        self.line = numbers[0]
        self.startColumn = numbers[1]
        self.endColumn = numbers.count == 3 ? max(numbers[2], numbers[1]) : numbers[1]
    }

    /// The UTF-16 range of the linked object in `text`, or nil if the line
    /// doesn't exist. Columns past the end of the line are clamped to it.
    public func range(in text: NSString) -> NSRange? {
        guard let lineRange = TextLines.range(ofLine: line, in: text) else { return nil }
        let lineText = text.substring(with: lineRange)
        let start = TextLines.utf16Offset(ofScalarColumn: startColumn, in: lineText)
        let end = TextLines.utf16Offset(ofScalarColumn: endColumn, in: lineText)
        return NSRange(location: lineRange.location + start, length: max(0, end - start))
    }

    /// Builds the link for a UTF-16 location in `text` (used to match the
    /// editor cursor against links in the PDF).
    public static func position(of location: Int, in text: NSString) -> (line: Int, column: Int) {
        let line = TextLines.lineNumber(at: location, in: text)
        let lineStart = TextLines.range(ofLine: line, in: text)?.location ?? 0
        let prefix = text.substring(with: NSRange(location: lineStart, length: max(0, location - lineStart)))
        return (line, prefix.unicodeScalars.count)
    }
}

/// Line helpers shared by the link, log and outline code.
public enum TextLines {
    /// Range of the 1-based `line`, without its line terminator.
    public static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var location = 0
        var current = 1
        while true {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: location, length: 0))
            if current == line {
                return NSRange(location: location, length: contentsEnd - location)
            }
            // The last line has no terminator, so there is no next line.
            if contentsEnd == end { return nil }
            location = end
            current += 1
        }
    }

    /// 1-based line number of a UTF-16 location.
    public static func lineNumber(at location: Int, in text: NSString) -> Int {
        let end = min(max(location, 0), text.length)
        var line = 1
        var i = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        while i < end {
            let chunk = min(buffer.count, end - i)
            buffer.withUnsafeMutableBufferPointer { ptr in
                text.getCharacters(ptr.baseAddress!, range: NSRange(location: i, length: chunk))
            }
            for k in 0..<chunk {
                let c = buffer[k]
                if c == 0x0A {
                    line += 1
                } else if c == 0x0D {
                    // CRLF counts once.
                    let nextIndex = i + k + 1
                    let next: unichar = k + 1 < chunk ? buffer[k + 1]
                        : (nextIndex < text.length ? text.character(at: nextIndex) : 0)
                    if next != 0x0A { line += 1 }
                }
            }
            i += chunk
        }
        return line
    }

    /// Converts a column counted in Unicode scalars (as LilyPond counts) to a
    /// UTF-16 offset within `line`. Clamped to the line length.
    public static func utf16Offset(ofScalarColumn column: Int, in line: String) -> Int {
        var offset = 0
        var count = 0
        for scalar in line.unicodeScalars {
            if count >= column { break }
            offset += scalar.utf16.count
            count += 1
        }
        return offset
    }
}
