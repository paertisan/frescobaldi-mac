import Foundation

/// Start offsets of the lines of a text (split at `\n`, so a CRLF line
/// counts once), with binary-search lookup. Rebuilt after each edit; that's
/// a linear scan, fine for scores of any realistic size.
public struct LineIndex: Equatable, Sendable {
    /// UTF-16 offset where each line starts; `starts[0] == 0`.
    public private(set) var starts: [Int] = [0]
    public private(set) var length = 0

    public init() {}

    public init(_ text: NSString) {
        rebuild(text)
    }

    public mutating func rebuild(_ text: NSString) {
        length = text.length
        var result = [0]
        var buffer = [unichar](repeating: 0, count: 8192)
        var location = 0
        while location < length {
            let chunk = min(buffer.count, length - location)
            buffer.withUnsafeMutableBufferPointer { ptr in
                text.getCharacters(ptr.baseAddress!, range: NSRange(location: location, length: chunk))
            }
            for k in 0..<chunk where buffer[k] == 0x0A {
                result.append(location + k + 1)
            }
            location += chunk
        }
        starts = result
    }

    public var lineCount: Int { starts.count }

    /// 0-based line containing `location` (the end of the text belongs to the last line).
    public func line(at location: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of the 0-based `line`, including its line break.
    public func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }
}
