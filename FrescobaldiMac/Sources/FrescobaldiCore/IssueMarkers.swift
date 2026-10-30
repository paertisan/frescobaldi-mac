import Foundation

/// How an edit moves line numbers, so issue markers and messages stay on
/// their line while the user types.
public struct LineEdit: Equatable, Sendable {
    // 0-based lines of the text before the edit.
    private let startLine: Int
    private let endLine: Int
    private let startsAtLineStart: Bool
    private let endsAtLineStart: Bool
    /// 0-based line, after the edit, where the new text ends.
    private let newEndLine: Int
    private let delta: Int

    /// `oldLength` UTF-16 units at `location` became `newLength`; `old` and
    /// `new` index the text before and after.
    public init(location: Int, oldLength: Int, newLength: Int, old: LineIndex, new: LineIndex) {
        startLine = old.line(at: location)
        endLine = old.line(at: location + oldLength)
        startsAtLineStart = old.starts[startLine] == location
        endsAtLineStart = old.starts[endLine] == location + oldLength
        newEndLine = new.line(at: location + newLength)
        delta = new.lineCount - old.lineCount
    }

    /// No line moves: the edit stayed within one line.
    public var isIdentity: Bool { delta == 0 && startLine == endLine }

    /// Where 1-based `line` is after the edit, or nil if the edit removed it.
    public func map(_ line: Int) -> Int? {
        let l = line - 1
        if l < startLine { return line }
        // Starts where the edit ends (or after): moves with the lines added
        // or removed.
        if l > endLine || (l == endLine && endsAtLineStart) { return line + delta }
        // Has text before the edit: stays.
        if l == startLine && !startsAtLineStart { return line }
        // Has text after the edit: joins the line where the new text ends.
        if l == endLine { return newEndLine + 1 }
        return nil
    }

    /// Like `map`, but a removed line goes where the edit happened.
    public func nearest(_ line: Int) -> Int { map(line) ?? startLine + 1 }
}

/// The dots in the editor's gutter for every file: 1-based line → the most
/// severe message on it, from the last engrave that read the file.
public struct IssueMarkers: Equatable, Sendable {
    public typealias Lines = [Int: LilyPondMessage.Severity]

    /// By normalized path (see `key`).
    public private(set) var files: [String: Lines] = [:]

    public init() {}

    public static func key(_ path: String) -> String { LilyPondProject.normalized(URL(fileURLWithPath: path)) }

    public func lines(for path: String) -> Lines { files[Self.key(path)] ?? [:] }

    /// After a run that read the files at `paths`: their markers become those
    /// of `messages`, none for a file without messages, so a clean engrave
    /// clears them; other files keep theirs. Returns the keys that changed.
    @discardableResult
    public mutating func update(with messages: [LilyPondMessage], covering paths: Set<String>) -> Set<String> {
        var found: [String: Lines] = [:]
        for message in messages where message.isLocated {
            Self.mark(&found[Self.key(message.file), default: [:]], line: message.line, severity: message.severity)
        }
        var changed: Set<String> = []
        for key in Set(paths.map(Self.key)).union(found.keys) {
            let lines = found[key] ?? [:]
            if (files[key] ?? [:]) != lines { changed.insert(key) }
            files[key] = lines.isEmpty ? nil : lines
        }
        return changed
    }

    /// Moves the markers of the file at `path` with an edit. Returns whether
    /// any moved.
    @discardableResult
    public mutating func apply(_ edit: LineEdit, to path: String) -> Bool {
        let key = Self.key(path)
        guard !edit.isIdentity, let lines = files[key] else { return false }
        var moved: Lines = [:]
        for (line, severity) in lines {
            if let to = edit.map(line) { Self.mark(&moved, line: to, severity: severity) }
        }
        guard moved != lines else { return false }
        files[key] = moved.isEmpty ? nil : moved
        return true
    }

    /// `messages` with those in the file at `path` moved by an edit.
    public static func move(_ messages: [LilyPondMessage], by edit: LineEdit, in path: String) -> [LilyPondMessage] {
        guard !edit.isIdentity else { return messages }
        let key = key(path)
        return messages.map { message in
            guard message.isLocated, Self.key(message.file) == key else { return message }
            var message = message
            message.line = edit.nearest(message.line)
            return message
        }
    }

    /// An error wins over a warning on the same line.
    private static func mark(_ lines: inout Lines, line: Int, severity: LilyPondMessage.Severity) {
        if let existing = lines[line], existing.isError { return }
        lines[line] = severity
    }
}
