import Foundation

/// A command that builds the project another way (make, meson, a script),
/// listed in the toolbar's target menu.
public struct ProjectCommand: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Run with `/bin/sh -c`.
    public var command: String
    /// Working directory, relative to the project root; the root if nil.
    public var directory: String?

    public var id: String { "\(name)\u{0}\(command)" }

    public init(name: String, command: String, directory: String? = nil) {
        self.name = name
        self.command = command
        self.directory = directory
    }
}

/// `frescobaldi.json` at a project's root: settings that belong with the
/// project rather than the computer. Everything is optional; the app writes
/// the file only when the user changes one of these settings.
///
///     {
///       "targets": ["score.ly", "parts/flute.ly"],
///       "defaultTarget": "score.ly",
///       "includePaths": ["../openlilylib"],
///       "outputDirectory": "build",
///       "commands": [{ "name": "All parts", "command": "make parts" }]
///     }
public struct ProjectSettings: Codable, Equatable, Sendable {
    public static let fileName = "frescobaldi.json"

    /// Files to engrave, relative to the root. Nil: every `.ly` file that
    /// makes output by itself.
    public var targets: [String]?
    /// What ⌘R engraves for a file that several targets include.
    public var defaultTarget: String?
    /// Extra folders LilyPond searches for `\include` files (`-I`), relative
    /// to the root, absolute or starting with `~`.
    public var includePaths: [String]
    /// Where PDF and MIDI files go; next to each target if nil.
    public var outputDirectory: String?
    public var commands: [ProjectCommand]

    public init(targets: [String]? = nil, defaultTarget: String? = nil, includePaths: [String] = [],
                outputDirectory: String? = nil, commands: [ProjectCommand] = []) {
        self.targets = targets
        self.defaultTarget = defaultTarget
        self.includePaths = includePaths
        self.outputDirectory = outputDirectory
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case targets, defaultTarget, includePaths, outputDirectory, commands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([String].self, forKey: .targets)
        defaultTarget = try c.decodeIfPresent(String.self, forKey: .defaultTarget)
        includePaths = try c.decodeIfPresent([String].self, forKey: .includePaths) ?? []
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory)
        commands = try c.decodeIfPresent([ProjectCommand].self, forKey: .commands) ?? []
    }

    /// Leaves out what isn't set, so the file stays short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(targets, forKey: .targets)
        try c.encodeIfPresent(defaultTarget.flatMap { $0.isEmpty ? nil : $0 }, forKey: .defaultTarget)
        if !includePaths.isEmpty { try c.encode(includePaths, forKey: .includePaths) }
        try c.encodeIfPresent(outputDirectory.flatMap { $0.isEmpty ? nil : $0 }, forKey: .outputDirectory)
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    }

    public var isEmpty: Bool { self == ProjectSettings() }

    // MARK: File

    /// The nearest folder at or above `directory` with a `frescobaldi.json`,
    /// looking at most eight levels up and not above the home folder.
    public static func root(containing directory: URL, fileManager: FileManager = .default) -> URL? {
        var current = directory.standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: current.appendingPathComponent(fileName).path) { return current }
            let parent = current.deletingLastPathComponent()
            if current.path == home || parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    public static func load(root: URL) throws -> ProjectSettings {
        let data = try Data(contentsOf: root.appendingPathComponent(fileName))
        return try JSONDecoder().decode(ProjectSettings.self, from: data)
    }

    /// Writes `frescobaldi.json`, sorted and indented for version control.
    public func write(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // MARK: Paths

    /// A path from the file: absolute, `~/...`, or relative to the root.
    public static func url(_ path: String, root: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return root.appendingPathComponent(expanded).standardizedFileURL
    }

    public func includeDirectories(root: URL) -> [URL] {
        includePaths.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { Self.url($0, root: root) }
    }

    public func outputDirectory(root: URL) -> URL? {
        guard let outputDirectory, !outputDirectory.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Self.url(outputDirectory, root: root)
    }

    /// LilyPond's `-o` for `target`: `<output folder>/<name>`, or nil to
    /// write next to the target.
    public func outputBase(for target: URL, root: URL) -> URL? {
        outputDirectory(root: root)?.appendingPathComponent(target.deletingPathExtension().lastPathComponent)
    }

    /// Extra LilyPond arguments: `-I` for each include path.
    public func lilypondArguments(root: URL) -> [String] {
        includeDirectories(root: root).flatMap { ["-I", $0.path] }
    }
}
