import Foundation

/// One error or warning from a LilyPond run.
public struct LilyPondMessage: Equatable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable, CaseIterable {
        case error
        case warning
        case programmingError = "programming error"
        case fatalError = "fatal error"

        public var isError: Bool { self != .warning }
    }

    /// Empty for a message without a location, such as an unknown paper size.
    public var file: String
    /// 1-based line; 0 without a location.
    public var line: Int
    /// 1-based column, in characters; 0 without one (`file:1: warning: no
    /// \version statement found`).
    public var column: Int
    public var severity: Severity
    public var message: String
    /// The lines LilyPond prints after the message: usually the source line
    /// split at the error position, for a Scheme error also the line that
    /// explains it.
    public var context: [String]
    /// Index of the message line in the log (also used as the identity).
    public var logLine: Int

    public var id: Int { logLine }

    /// Whether the message points at a place in a file.
    public var isLocated: Bool { !file.isEmpty && line > 0 }

    public init(file: String, line: Int, column: Int, severity: Severity, message: String,
                context: [String] = [], logLine: Int = 0) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.context = context
        self.logLine = logLine
    }

    /// The location as a 0-based scalar column link, for jumping the editor.
    public var link: TextEditLink {
        TextEditLink(path: file, line: line, startColumn: max(0, column - 1), endColumn: max(0, column - 1))
    }
}

/// Parses LilyPond's log output (stderr).
///
/// Messages look like `file:LINE:COL: error: text`, COL 1-based, followed by
/// two context lines (the source line split at the column), `file:LINE:
/// warning: text`, or `warning: text` without a location. `fatal error: failed files: ...` is a
/// summary and is skipped.
public enum LilyPondLogParser {
    private static let messagePattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+)(?::(\d+))?: (error|warning|programming error|fatal error): (.*)$"#)
    private static let unlocatedPattern = try! NSRegularExpression(
        pattern: #"^(error|warning|programming error|fatal error): (.*)$"#)
    /// Most context a message keeps.
    static let maxContext = 6
    private static let outputPattern = try! NSRegularExpression(
        pattern: #"(?:Converting to|MIDI output to) [`'"‘](.+?)['"’]\.\.\."#)

    public static func parse(_ log: String) -> [LilyPondMessage] {
        let lines = splitLines(log)
        var result: [LilyPondMessage] = []
        var index = 0
        while index < lines.count {
            guard var message = parseMessage(lines[index], logLine: index) else {
                index += 1
                continue
            }
            // A message with a column has two source lines first (the first
            // is empty for column 1); after them, or for a message without a
            // column, more lines until a blank line, such as the one that
            // explains a Scheme error.
            var context: [String] = []
            var next = index + 1
            while context.count < maxContext && next < lines.count && parseMessage(lines[next], logLine: next) == nil
                    && !isProgressLine(lines[next]) {
                let line = lines[next]
                if line.isEmpty && (message.column == 0 || context.count >= 2) { break }
                context.append(line)
                next += 1
            }
            // `cannot find file` prints the search path before the source.
            message.context = context.filter { !$0.hasPrefix("(search path:") }
            result.append(message)
            index = next
        }
        return result
    }

    /// Parses one log line, or returns nil if it isn't a message.
    public static func parseMessage(_ line: String, logLine: Int = 0) -> LilyPondMessage? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = messagePattern.firstMatch(in: line, range: range) else {
            guard let m = unlocatedPattern.firstMatch(in: line, range: range),
                  let severity = LilyPondMessage.Severity(rawValue: ns.substring(with: m.range(at: 1))) else {
                return nil
            }
            let text = ns.substring(with: m.range(at: 2))
            if severity == .fatalError && text.hasPrefix("failed files") { return nil }
            return LilyPondMessage(file: "", line: 0, column: 0, severity: severity, message: text, logLine: logLine)
        }
        let file = ns.substring(with: m.range(at: 1))
        let columnRange = m.range(at: 3)
        guard let lineNumber = Int(ns.substring(with: m.range(at: 2))),
              let column = columnRange.location == NSNotFound ? 0 : Int(ns.substring(with: columnRange)),
              let severity = LilyPondMessage.Severity(rawValue: ns.substring(with: m.range(at: 4))) else {
            return nil
        }
        let text = ns.substring(with: m.range(at: 5))
        if severity == .fatalError && text.hasPrefix("failed files") { return nil }
        return LilyPondMessage(file: file, line: lineNumber, column: column, severity: severity,
                               message: text, logLine: logLine)
    }

    /// Output files announced in the log, in order (`Converting to `x.pdf'...`,
    /// `MIDI output to `x.midi'...`). Paths are as LilyPond printed them,
    /// usually relative to its working directory.
    public static func outputFiles(in log: String) -> [String] {
        var result: [String] = []
        for line in splitLines(log) {
            let ns = line as NSString
            for m in outputPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1))
                if !result.contains(path) { result.append(path) }
            }
        }
        return result
    }

    private static let directoryPattern = try! NSRegularExpression(
        pattern: #"^(?:\S*make(?:\[\d+\])?: (Entering|Leaving) directory|ninja: (Entering) directory|(Changing) working directory to:?) [`'"‘](.+?)['"’]"#)

    /// The working directory in effect at each log line, following make's
    /// `Entering directory` / `Leaving directory`, ninja's `Entering
    /// directory` and LilyPond's `Changing working directory to`.
    static func directories(in lines: [String], base: URL) -> [URL] {
        var stack = [base.standardizedFileURL]
        var result: [URL] = []
        for line in lines {
            result.append(stack[stack.count - 1])
            let ns = line as NSString
            guard let m = directoryPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let path = ns.substring(with: m.range(at: 4))
            let url = URL(fileURLWithPath: path, relativeTo: stack[stack.count - 1]).standardizedFileURL
            if m.range(at: 1).location != NSNotFound && ns.substring(with: m.range(at: 1)) == "Leaving" {
                if stack.count > 1 { stack.removeLast() }
            } else if m.range(at: 3).location != NSNotFound {
                stack[stack.count - 1] = url
            } else {
                stack.append(url)
            }
        }
        return result
    }

    /// Makes relative message paths absolute, for logs of build commands
    /// that run LilyPond in other directories: relative to the directory in
    /// effect at that line, else to `base`.
    public static func resolvingPaths(_ messages: [LilyPondMessage], in log: String, base: URL) -> [LilyPondMessage] {
        let directories = directories(in: splitLines(log), base: base)
        return messages.map { message in
            guard !message.file.isEmpty else { return message }
            var message = message
            message.file = resolve(message.file, at: message.logLine, directories: directories, base: base).path
            return message
        }
    }

    /// Output files announced in a build command's log, as absolute URLs.
    public static func outputFiles(in log: String, base: URL) -> [URL] {
        let lines = splitLines(log)
        let directories = directories(in: lines, base: base)
        var result: [URL] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            for m in outputPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let url = resolve(ns.substring(with: m.range(at: 1)), at: index, directories: directories, base: base)
                if !result.contains(url) { result.append(url) }
            }
        }
        return result
    }

    private static func resolve(_ path: String, at line: Int, directories: [URL], base: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        let directory = line < directories.count ? directories[line] : base
        let candidate = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let fallback = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : candidate
    }

    /// Lines like `Processing `x.ly'`, `Parsing...`, `Interpreting music...`
    /// that end a message's context early.
    static func isProgressLine(_ line: String) -> Bool {
        let prefixes = ["Processing `", "Parsing...", "Interpreting music...", "Preprocessing graphical objects...",
                        "Finding the ideal number of pages...", "Fitting music on", "Drawing systems...",
                        "Converting to", "MIDI output to", "Success: compilation", "Layout output to",
                        "GNU LilyPond", "Changing working directory to", "make: ", "make[", "ninja: "]
        return prefixes.contains { line.hasPrefix($0) }
    }

    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in lines.append(line) }
        return lines
    }
}
