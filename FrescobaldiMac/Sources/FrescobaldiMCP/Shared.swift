import Foundation
import FrescobaldiCore

/// Engrave results as JSON, for the `engrave` tool and the app's bridge.
public enum EngraveReport {
    public static func json(_ result: EngraveJob.Result) -> JSONValue {
        let errors = result.messages.filter { $0.severity.isError }.count
        let status = result.cancelled ? "cancelled" : (result.succeeded && errors == 0 ? "succeeded" : "failed")
        var object: [String: JSONValue] = [
            "status": .string(status),
            "errors": .int(errors),
            "warnings": .int(result.messages.count - errors),
            "issues": .array(result.messages.map(issue)),
            "pdfs": JSONValue(result.pdfs.map(\.path)),
            "midis": JSONValue(result.midis.map(\.path)),
            "duration_seconds": .double((result.duration * 10).rounded() / 10),
        ]
        if status != "succeeded" {
            // The end of the log explains failures the parser doesn't catch.
            let lines = result.log.split(separator: "\n", omittingEmptySubsequences: false)
            object["log_tail"] = .string(lines.suffix(25).joined(separator: "\n"))
        }
        return .object(object)
    }

    public static func issue(_ message: LilyPondMessage) -> JSONValue {
        var object: [String: JSONValue] = [
            "severity": .string(message.severity.rawValue),
            "message": .string(message.message),
        ]
        // A message without a location (an unknown paper size) has no file.
        if message.isLocated {
            object["file"] = .string(message.file)
            object["line"] = .int(message.line)
            object["column"] = .int(message.column)
        }
        if !message.context.isEmpty { object["context"] = .string(message.context.joined(separator: "\n")) }
        return .object(object)
    }
}

/// The Tools-menu operations as tool arguments (shared by the `transform`
/// tool and the app's bridge).
public enum LyEditArguments {
    public static let operations = [
        "transpose", "translate", "relative_to_absolute", "absolute_to_relative",
        "simplify_accidentals", "reindent", "reformat",
    ]

    public static func edit(from arguments: JSONValue) throws -> LyEdit {
        guard let operation = arguments["operation"]?.string else {
            throw MCPToolError("Missing operation; one of: \(operations.joined(separator: ", ")).")
        }
        switch operation {
        case "transpose":
            guard let from = arguments["from"]?.string, let to = arguments["to"]?.string,
                  !from.isEmpty, !to.isEmpty else {
                throw MCPToolError("transpose needs `from` and `to` pitches in Dutch names, e.g. c and d, or bes and c'.")
            }
            return .transpose(from: from.trimmingCharacters(in: .whitespaces), to: to.trimmingCharacters(in: .whitespaces))
        case "translate":
            guard let language = arguments["language"]?.string?.lowercased(), LyEdit.languages.contains(language) else {
                throw MCPToolError("translate needs `language`: one of \(LyEdit.languages.joined(separator: ", ")).")
            }
            return .translate(language: language)
        case "relative_to_absolute": return .relativeToAbsolute
        case "absolute_to_relative": return .absoluteToRelative
        case "simplify_accidentals": return .simplifyAccidentals
        case "reindent": return .indent
        case "reformat": return .reformat
        default:
            throw MCPToolError("Unknown operation \(operation); one of: \(operations.joined(separator: ", ")).")
        }
    }

    /// The name shown in Edit > Undo.
    public static func undoName(_ edit: LyEdit) -> String {
        switch edit {
        case .transpose: "Transpose"
        case .translate: "Translate Pitch Names"
        case .relativeToAbsolute: "Relative to Absolute"
        case .absoluteToRelative: "Absolute to Relative"
        case .simplifyAccidentals: "Simplify Accidentals"
        case .indent: "Re-indent"
        case .reformat: "Reformat"
        }
    }
}

/// Where the helper finds LilyPond, python-ly and the templates: inside
/// Frescobaldi.app (Contents/Helpers/frescobaldi-mcp → Contents/Resources),
/// or next to the Swift package during development.
public struct FrescobaldiEnvironment: Sendable {
    public var resources: URL?
    public var pythonLyDirectory: URL?
    /// The LilyPond location chosen in Frescobaldi's Settings ("" = automatic).
    public var lilypondSetting: String

    public static let appDefaultsDomain = "io.github.paertisan.frescobaldi"

    public init(resources: URL?, pythonLyDirectory: URL?, lilypondSetting: String) {
        self.resources = resources
        self.pythonLyDirectory = pythonLyDirectory
        self.lilypondSetting = lilypondSetting
    }

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> FrescobaldiEnvironment {
        let fm = FileManager.default
        func isResources(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("python/fmac_lytool.py").path)
                && fm.fileExists(atPath: url.appendingPathComponent("Templates").path)
        }
        var resources: URL?
        if let override = environment["FRESCOBALDI_RESOURCES"] {
            resources = URL(fileURLWithPath: override)
        } else if var url = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            for _ in 0..<6 {
                url.deleteLastPathComponent()
                let candidate = url.appendingPathComponent("Resources")
                if isResources(candidate) {
                    resources = candidate
                    break
                }
            }
        }

        var lyCandidates: [URL] = []
        if let dir = environment["PYTHON_LY_DIR"] { lyCandidates.append(URL(fileURLWithPath: dir)) }
        if let resources {
            lyCandidates.append(resources.appendingPathComponent("python"))
            // Development: python-ly fetched by scripts/build-app.sh.
            lyCandidates.append(resources.deletingLastPathComponent().appendingPathComponent("build/python"))
        }
        let pythonLy = lyCandidates.first { fm.fileExists(atPath: $0.appendingPathComponent("ly/__init__.py").path) }

        let setting = environment["FRESCOBALDI_LILYPOND"]
            ?? UserDefaults(suiteName: appDefaultsDomain)?.string(forKey: "lilypondPath") ?? ""
        return FrescobaldiEnvironment(resources: resources, pythonLyDirectory: pythonLy, lilypondSetting: setting)
    }

    public func lilypond() -> URL? {
        LilyPondLocator.locate(userSetting: lilypondSetting)
    }

    public var templatesDirectory: URL? {
        resources?.appendingPathComponent("Templates", isDirectory: true)
    }

    public func pythonLyTool() throws -> PythonLyTool {
        guard let python = PythonLyTool.findPython() else {
            throw MCPToolError("Python 3 wasn't found. Install the Xcode Command Line Tools or Homebrew's python.")
        }
        guard let resources, let pythonLyDirectory else {
            throw MCPToolError("python-ly wasn't found next to frescobaldi-mcp. Run the helper from Frescobaldi.app.")
        }
        return PythonLyTool(pythonLyDirectory: pythonLyDirectory,
                            driverScript: resources.appendingPathComponent("python/fmac_lytool.py"), python: python)
    }
}
