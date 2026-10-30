import Foundation

/// Frescobaldi's document variables: `-*- master: ../score.ly; indent-width: 2 -*-`
/// in a comment in the first or last five lines of a file.
public enum DocumentVariables {
    public static func parse(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let candidates = lines.count <= 10 ? Array(lines) : Array(lines.prefix(5) + lines.suffix(5))
        var variables: [String: String] = [:]
        for line in candidates {
            guard let start = line.range(of: "-*-") else { continue }
            var body = line[start.upperBound...]
            if let end = body.range(of: "-*-") { body = body[..<end.lowerBound] }
            for assignment in body.split(separator: ";") {
                let parts = assignment.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !value.isEmpty { variables[name] = value }
            }
        }
        return variables
    }

    /// The file to engrave instead of `url`, from its `master` variable.
    public static func master(for url: URL, text: String) -> URL? {
        guard let master = parse(text)["master"] else { return nil }
        let expanded = (master as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return url.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }
}

/// One `\include` in a project's include tree (the root is the main file).
public struct IncludeNode: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        /// Found in the project (or next to it).
        case ok
        case missing
        /// One of LilyPond's own files (english.ly, articulate.ly, ...).
        case system
        /// Includes itself, directly or through other files.
        case cycle
        /// Not followed further (too deep or too many files).
        case truncated
    }

    public var id: String
    /// The path as written in the `\include` (the file name for the root).
    public var written: String
    public var url: URL?
    /// Line of the `\include` in the including file (0 for the root).
    public var line: Int
    public var status: Status
    /// Written as an absolute path, so the project only builds on this computer.
    public var isAbsolute: Bool
    /// Resolves to a file outside the project folder.
    public var isOutsideProject: Bool
    public var children: [IncludeNode]

    /// For SwiftUI's outline lists: nil for leaves.
    public var childrenOrNil: [IncludeNode]? { children.isEmpty ? nil : children }
}

public struct ProjectProblem: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case error, warning, hint
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var severity: Severity
    public var message: String
    /// The file to show: the one with the `\include`, or the file concerned.
    public var file: URL
    public var line: Int?
    public var id: String { "\(file.path):\(line ?? 0):\(message)" }
}

/// A file or folder in the project folder.
public struct ProjectFile: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var children: [ProjectFile]
    public var id: String { url.path }
    public var childrenOrNil: [ProjectFile]? { isDirectory ? children : nil }
}

/// A LilyPond project: a main file, everything it includes (recursively),
/// the files in its folder, and what could be organized better.
public struct LilyPondProject: Sendable {
    public var main: URL
    /// The main file's folder.
    public var root: URL
    public var tree: IncludeNode
    /// Standardized paths of the main file and every file it includes.
    public var includedPaths: Set<String>
    public var files: [ProjectFile]
    public var problems: [ProjectProblem]

    public typealias Reader = @Sendable (URL) -> String?

    /// Reads files from disk; pass a reader that prefers open documents' text.
    public static let diskReader: Reader = { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    public static let sourceExtensions: Set<String> = ["ly", "ily", "lyi"]

    // MARK: Main file

    /// The file to engrave for `file`: its `master` variable, otherwise (for
    /// an include file) a `.ly` in its folder or up to two folders above
    /// that includes it, otherwise the file itself.
    public static func main(for file: URL, text: String, read: Reader = diskReader,
                            fileManager: FileManager = .default) -> URL {
        if let master = DocumentVariables.master(for: file, text: text),
           fileManager.fileExists(atPath: master.path) {
            return master
        }
        guard file.pathExtension.lowercased() != "ly" else { return file }
        let target = normalized(file)
        var directory = file.deletingLastPathComponent()
        for _ in 0..<3 {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.lowercased().hasSuffix(".ly") {
                let candidate = directory.appendingPathComponent(name)
                guard let text = read(candidate) else { continue }
                let tree = includeTree(main: candidate, text: text, read: read, fileManager: fileManager,
                                       limit: 500)
                if paths(in: tree).contains(target) { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return file
    }

    // MARK: Loading

    public static func load(main: URL, mainText: String? = nil, systemDirectories: [URL] = [],
                            read: Reader = diskReader, fileManager: FileManager = .default) -> LilyPondProject {
        let root = main.deletingLastPathComponent().standardizedFileURL
        let text = mainText ?? read(main) ?? ""
        let tree = includeTree(main: main, text: text, systemDirectories: systemDirectories, root: root,
                               read: read, fileManager: fileManager)
        let included = paths(in: tree)
        let files = scanFolder(root, fileManager: fileManager)
        var problems = treeProblems(tree, includer: main, root: root)
        if !text.contains("\\version") {
            problems.append(ProjectProblem(severity: .hint, message: "\(main.lastPathComponent) has no \\version; convert-ly needs it to update the syntax later.", file: main, line: 1))
        }

        // Include files nothing includes: not from this main file, nor from
        // any other .ly in the folder (such as parts).
        var reachable = included
        let mains = sourceFiles(in: files).filter { $0.pathExtension.lowercased() == "ly" && normalized($0) != normalized(main) }
        for other in mains.prefix(40) {
            guard let otherText = read(other) else { continue }
            reachable.formUnion(paths(in: includeTree(main: other, text: otherText, systemDirectories: systemDirectories,
                                                      root: root, read: read, fileManager: fileManager, limit: 1000)))
        }
        for file in sourceFiles(in: files) where file.pathExtension.lowercased() != "ly" {
            if !reachable.contains(normalized(file)) {
                problems.append(ProjectProblem(severity: .hint, message: "\(relativePath(file, to: root)) isn't included by any .ly file.", file: file, line: nil))
            }
        }
        problems.sort { ($0.severity, $0.file.path, $0.line ?? 0) < ($1.severity, $1.file.path, $1.line ?? 0) }
        return LilyPondProject(main: main, root: root, tree: tree, includedPaths: included, files: files,
                               problems: problems)
    }

    // MARK: Include tree

    /// Resolves an `\include` as LilyPond 2.26 does (relative-includes is on):
    /// relative to the including file, then to the main file's folder (the
    /// working directory), then in LilyPond's own `ly` folder.
    public static func resolve(_ written: String, from includer: URL, main: URL, systemDirectories: [URL],
                               fileManager: FileManager = .default) -> (url: URL?, isSystem: Bool) {
        let expanded = (written as NSString).expandingTildeInPath
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            return (exists(url) ? url : nil, false)
        }
        for directory in [includer.deletingLastPathComponent(), main.deletingLastPathComponent()] {
            let url = directory.appendingPathComponent(expanded).standardizedFileURL
            if exists(url) { return (url, false) }
        }
        for directory in systemDirectories {
            let url = directory.appendingPathComponent(expanded).standardizedFileURL
            if exists(url) { return (url, true) }
        }
        return (nil, false)
    }

    static func includeTree(main: URL, text: String, systemDirectories: [URL] = [], root: URL? = nil,
                            read: Reader, fileManager: FileManager, limit: Int = 3000) -> IncludeNode {
        let root = root ?? main.deletingLastPathComponent().standardizedFileURL
        var budget = limit
        func children(of file: URL, text: String, ancestors: [String], idPrefix: String) -> [IncludeNode] {
            let includes = DocumentOutline.items(in: text as NSString).filter { $0.kind == .include && $0.title != "\\include" }
            return includes.enumerated().map { index, item in
                budget -= 1
                let (url, isSystem) = resolve(item.title, from: file, main: main, systemDirectories: systemDirectories,
                                              fileManager: fileManager)
                let expanded = (item.title as NSString).expandingTildeInPath
                var node = IncludeNode(
                    id: "\(idPrefix)/\(index):\(item.title)", written: item.title, url: url, line: item.line,
                    status: .ok, isAbsolute: expanded.hasPrefix("/"),
                    isOutsideProject: url.map { !isSystem && !normalized($0).hasPrefix(normalized(root) + "/") } ?? false,
                    children: [])
                guard let url else {
                    node.status = .missing
                    return node
                }
                if isSystem {
                    node.status = .system
                    return node
                }
                let path = normalized(url)
                if ancestors.contains(path) {
                    node.status = .cycle
                    return node
                }
                guard budget > 0, ancestors.count < 30 else {
                    node.status = .truncated
                    return node
                }
                if let childText = read(url) {
                    node.children = children(of: url, text: childText, ancestors: ancestors + [path], idPrefix: node.id)
                }
                return node
            }
        }
        let path = normalized(main)
        return IncludeNode(id: path, written: main.lastPathComponent, url: main, line: 0, status: .ok,
                           isAbsolute: false, isOutsideProject: false,
                           children: children(of: main, text: text, ancestors: [path], idPrefix: path))
    }

    /// Standardized paths of every found file in the tree.
    public static func paths(in tree: IncludeNode) -> Set<String> {
        var result: Set<String> = []
        func visit(_ node: IncludeNode) {
            if let url = node.url, node.status != .system { result.insert(normalized(url)) }
            node.children.forEach(visit)
        }
        visit(tree)
        return result
    }

    /// Broken includes anywhere; organization hints only for includes written
    /// in the project's own files (not inside libraries it uses).
    private static func treeProblems(_ node: IncludeNode, includer: URL, root: URL) -> [ProjectProblem] {
        var problems: [ProjectProblem] = []
        let inProject = normalized(includer).hasPrefix(normalized(root) + "/")
        for child in node.children {
            let name = child.isAbsolute ? (child.written as NSString).lastPathComponent : child.written
            switch child.status {
            case .missing:
                problems.append(ProjectProblem(severity: .error, message: "\(name) wasn't found.", file: includer, line: child.line))
            case .cycle:
                problems.append(ProjectProblem(severity: .error, message: "\(name) includes itself (directly or through other files).", file: includer, line: child.line))
            case .ok, .system, .truncated:
                break
            }
            if inProject {
                if child.isAbsolute && child.status != .missing {
                    problems.append(ProjectProblem(severity: .warning, message: "\(name) is included by an absolute path, so the project only builds on this computer. Copy it into the project, or add its folder to LilyPond's include path (-I).", file: includer, line: child.line))
                } else if child.isOutsideProject {
                    problems.append(ProjectProblem(severity: .hint, message: "\(name) is outside the project folder.", file: includer, line: child.line))
                }
                if child.status == .ok, !child.isOutsideProject, child.url?.pathExtension.lowercased() == "ly" {
                    problems.append(ProjectProblem(severity: .hint, message: "\(name) is included; files meant for \\include are usually named .ily, and .ly is for files you engrave.", file: includer, line: child.line))
                }
            }
            if let url = child.url, child.status == .ok {
                problems += treeProblems(child, includer: url, root: root)
            }
        }
        return problems
    }

    // MARK: Folder

    /// The project folder's files and folders (hidden ones left out), folders
    /// first, in natural order.
    public static func scanFolder(_ root: URL, maxDepth: Int = 6, limit: Int = 3000,
                                  fileManager: FileManager = .default) -> [ProjectFile] {
        var remaining = limit
        func scan(_ directory: URL, depth: Int) -> [ProjectFile] {
            guard depth < maxDepth, remaining > 0,
                  let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
            var entries: [ProjectFile] = []
            for name in names where !name.hasPrefix(".") && remaining > 0 {
                remaining -= 1
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if ["app", "bundle", "lilypond-book"].contains(url.pathExtension) { continue }
                    entries.append(ProjectFile(url: url, isDirectory: true, children: scan(url, depth: depth + 1)))
                } else {
                    entries.append(ProjectFile(url: url, isDirectory: false, children: []))
                }
            }
            return entries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.url.lastPathComponent.compare(b.url.lastPathComponent,
                                                       options: [.numeric, .caseInsensitive]) == .orderedAscending
            }
        }
        return scan(root.standardizedFileURL, depth: 0)
    }

    static func sourceFiles(in files: [ProjectFile]) -> [URL] {
        files.flatMap { file -> [URL] in
            if file.isDirectory { return sourceFiles(in: file.children) }
            return sourceExtensions.contains(file.url.pathExtension.lowercased()) ? [file.url] : []
        }
    }

    // MARK: Paths

    public static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `url` relative to `root` when inside it, else its full path.
    public static func relativePath(_ url: URL, to root: URL) -> String {
        let path = normalized(url)
        let base = normalized(root)
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}
