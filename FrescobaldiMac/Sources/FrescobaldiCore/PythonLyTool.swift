import Foundation

/// Edits that python-ly performs on LilyPond source.
public enum LyEdit: Equatable, Sendable {
    /// Transpose from one pitch to another, both in Dutch names with octave
    /// marks (`c`, `bes,`, `fis'`).
    case transpose(from: String, to: String)
    /// Rewrite pitch names in another language (`english`, `deutsch`, ...).
    case translate(language: String)
    case relativeToAbsolute
    case absoluteToRelative
    case simplifyAccidentals
    case indent
    case reformat

    /// Pitch-name languages LilyPond and python-ly know.
    public static let languages = [
        "nederlands", "catalan", "deutsch", "english", "espanol", "italiano",
        "norsk", "portugues", "suomi", "svenska", "vlaams",
    ]

    var command: String {
        switch self {
        case .transpose: "transpose"
        case .translate: "translate"
        case .relativeToAbsolute: "rel2abs"
        case .absoluteToRelative: "abs2rel"
        case .simplifyAccidentals: "simplify_accidentals"
        case .indent: "indent"
        case .reformat: "reformat"
        }
    }

    var arguments: [String: String] {
        switch self {
        case let .transpose(from, to): ["from": from, "to": to]
        case let .translate(language): ["language": language]
        default: [:]
        }
    }
}

public enum PythonLyError: Error, Equatable, LocalizedError {
    case pythonNotFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            "Python 3 wasn't found. Install the Xcode Command Line Tools or Homebrew's python."
        case let .failed(message):
            message
        }
    }
}

/// Runs `fmac_lytool.py` (bundled next to python-ly) to apply a `LyEdit`.
public struct PythonLyTool: Sendable {
    /// Directory containing the `ly` package (python-ly's root).
    public var pythonLyDirectory: URL
    /// The driver script `fmac_lytool.py`.
    public var driverScript: URL
    public var python: URL

    public init(pythonLyDirectory: URL, driverScript: URL, python: URL) {
        self.pythonLyDirectory = pythonLyDirectory
        self.driverScript = driverScript
        self.python = python
    }

    /// Homebrew's python first, then the system one (which needs the Command
    /// Line Tools on macOS).
    public static func findPython(fileManager: FileManager = .default) -> URL? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Applies `edit` to `selection` of `text` (the whole text when nil) and
    /// returns the new full text. Blocks; call off the main thread.
    public func apply(_ edit: LyEdit, to text: String, selection: NSRange? = nil,
                      indentWidth: Int = 2) throws -> String {
        var request: [String: Any] = [
            "text": text,
            "command": edit.command,
            "args": edit.arguments,
            "indentWidth": indentWidth,
        ]
        if let selection, selection.length > 0 {
            let ns = text as NSString
            request["start"] = Self.scalarOffset(ofUTF16: selection.location, in: ns)
            request["end"] = Self.scalarOffset(ofUTF16: NSMaxRange(selection), in: ns)
        }
        let input = try JSONSerialization.data(withJSONObject: request)

        // The request goes through a file rather than a stdin pipe: a pipe's
        // write end can leak into another process spawned at the same moment
        // (seen with swift-corelibs-foundation), and then stdin never ends.
        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmac-lytool-\(UUID().uuidString).json")
        try input.write(to: requestFile)
        defer { try? FileManager.default.removeItem(at: requestFile) }

        let process = Process()
        process.executableURL = python
        // -B: never write __pycache__ into the (signed) app bundle.
        process.arguments = ["-I", "-B", driverScript.path, pythonLyDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = try FileHandle(forReadingFrom: requestFile)
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw PythonLyError.pythonNotFound }

        // Read stderr concurrently so a chatty process can't block on a full pipe.
        let errorData = ErrorCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        guard let reply = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            let message = String(decoding: errorData.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PythonLyError.failed(message.isEmpty ? "python-ly exited with status \(process.terminationStatus)" : message)
        }
        if let error = reply["error"] as? String { throw PythonLyError.failed(error) }
        guard let newText = reply["text"] as? String else { throw PythonLyError.failed("python-ly returned no text") }
        return newText
    }

    /// Converts a UTF-16 offset to a Unicode scalar offset (Python indices).
    public static func scalarOffset(ofUTF16 offset: Int, in text: NSString) -> Int {
        let clamped = min(max(offset, 0), text.length)
        return text.substring(to: clamped).unicodeScalars.count
    }
}

private final class ErrorCollector: @unchecked Sendable {
    var data = Data()
}

/// The smallest single replacement that turns one text into another, so an
/// edit from python-ly becomes one small, undoable change.
public struct TextReplacement: Equatable, Sendable {
    /// UTF-16 range in the old text.
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// Nil when the texts are equal.
    public static func between(_ old: String, _ new: String) -> TextReplacement? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        if prefix == a.count && prefix == b.count { return nil }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix
                && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        // Don't split surrogate pairs.
        func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }
        func splitsPair(_ text: [UInt16], at index: Int) -> Bool {
            index > 0 && index < text.count && isLowSurrogate(text[index])
        }
        while prefix > 0 && (splitsPair(a, at: prefix) || splitsPair(b, at: prefix)) { prefix -= 1 }
        while suffix > 0 && (splitsPair(a, at: a.count - suffix) || splitsPair(b, at: b.count - suffix)) {
            suffix -= 1
        }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return TextReplacement(range: NSRange(location: prefix, length: a.count - suffix - prefix),
                               replacement: replacement)
    }
}
