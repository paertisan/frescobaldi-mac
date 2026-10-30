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
    /// Found in one of the project's include paths (`-I`).
    public var isFromIncludePath = false
    /// At top level or in a `\book`, so the file's scores are part of the
    /// output (see `TopLevelSummary.Include.isSection`).
    public var isSection = true
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

/// Reads and lexes each file once while a project loads.
final class SourceCache {
    let read: LilyPondProject.Reader
    private var texts: [String: String?] = [:]
    private var summaries: [String: TopLevelSummary] = [:]

    init(read: @escaping LilyPondProject.Reader) { self.read = read }

    func text(_ url: URL) -> String? {
        let key = LilyPondProject.normalized(url)
        if let cached = texts[key] { return cached }
        let text = read(url)
        texts[key] = .some(text)
        return text
    }

    func set(_ text: String, for url: URL) {
        let key = LilyPondProject.normalized(url)
        texts[key] = .some(text)
        summaries[key] = nil
    }

    func summary(_ url: URL) -> TopLevelSummary? {
        let key = LilyPondProject.normalized(url)
        if let cached = summaries[key] { return cached }
        guard let text = text(url) else { return nil }
        let summary = DocumentOutline.topLevel(in: text as NSString)
        summaries[key] = summary
        return summary
    }
}

/// A LilyPond project, seen from one of its files: the project folder, its
/// settings, the files that make output (targets), what to engrave for that
/// file, everything the main file includes, and what could be organized
/// better.
public struct LilyPondProject: Sendable {
    /// The file the project was opened for (a window's document).
    public var file: URL
    /// The file whose includes are shown: `target`, or `file` itself when
    /// there's nothing to engrave.
    public var main: URL
    /// The project folder: where `frescobaldi.json` is; otherwise the main
    /// file's folder, or the one above it when the main file includes files
    /// from there (as `parts/flute.ly` includes `../music/flute.ily`).
    public var root: URL
    /// `frescobaldi.json`, if the project has one.
    public var settings: ProjectSettings?
    /// The files to engrave: from `frescobaldi.json`, or every `.ly` file
    /// that makes output and isn't included inside another file's music.
    /// Files at the root come first.
    public var targets: [URL]
    /// What ⌘R engraves for `file`: itself if it's a target, its `master`,
    /// or a target that includes it (the default target if several do).
    /// Nil when it makes no output and nothing includes it.
    public var target: URL?
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

    public var settingsURL: URL { root.appendingPathComponent(ProjectSettings.fileName) }
    public var includeDirectories: [URL] { settings?.includeDirectories(root: root) ?? [] }
    public var outputDirectory: URL? { settings?.outputDirectory(root: root) }
    public var commands: [ProjectCommand] { settings?.commands ?? [] }

    /// LilyPond's `-o` (nil: next to the file) and extra arguments for
    /// engraving `target`.
    public func engraveOptions(for target: URL) -> (outputBase: URL?, arguments: [String]) {
        (settings?.outputBase(for: target, root: root), settings?.lilypondArguments(root: root) ?? [])
    }

    /// `url` relative to the project folder.
    public func relativePath(_ url: URL) -> String { Self.relativePath(url, to: root) }

    // MARK: Main file

    /// The file to engrave for `file`: its `master` variable, otherwise (for
    /// an include file) a `.ly` in its folder or up to two folders above
    /// that includes it, otherwise the file itself.
    public static func main(for file: URL, text: String, read: @escaping Reader = diskReader,
                            fileManager: FileManager = .default) -> URL {
        let cache = SourceCache(read: read)
        cache.set(text, for: file)
        return main(for: file, cache: cache, includeDirectories: [], fileManager: fileManager)
    }

    static func main(for file: URL, cache: SourceCache, includeDirectories: [URL],
                     fileManager: FileManager) -> URL {
        if let master = DocumentVariables.master(for: file, text: cache.text(file) ?? ""),
           fileManager.fileExists(atPath: master.path) {
            return master
        }
        guard file.pathExtension.lowercased() != "ly" else { return file }
        return includer(of: file, cache: cache, includeDirectories: includeDirectories, levels: 3,
                        fileManager: fileManager) ?? file
    }

    /// A `.ly` in `file`'s folder, or up to `levels - 1` folders above, that
    /// includes it (directly or not).
    static func includer(of file: URL, cache: SourceCache, includeDirectories: [URL], levels: Int,
                         fileManager: FileManager) -> URL? {
        let target = normalized(file)
        var directory = file.deletingLastPathComponent()
        for _ in 0..<levels {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.lowercased().hasSuffix(".ly") {
                let candidate = directory.appendingPathComponent(name)
                guard normalized(candidate) != target, cache.text(candidate) != nil else { continue }
                let tree = includeTree(main: candidate, cache: cache, includeDirectories: includeDirectories,
                                       fileManager: fileManager, limit: 500)
                if paths(in: tree).contains(target) { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Without a `frescobaldi.json`: the main file's folder, or the folder
    /// above when the main file includes files from there, or when an
    /// include file nothing includes sits next to `.ly` files one level up.
    /// (A `.ly` that a `.ly` one level up includes counts as an include file.)
    static func guessRoot(for file: URL, cache: SourceCache, fileManager: FileManager) -> URL {
        var main = main(for: file, cache: cache, includeDirectories: [], fileManager: fileManager)
        if normalized(main) == normalized(file), file.pathExtension.lowercased() == "ly" {
            if let includer = includer(of: file, cache: cache, includeDirectories: [], levels: 2, fileManager: fileManager) {
                main = includer
            } else if siblingIncludes(file, cache: cache, fileManager: fileManager) {
                return file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            }
        }
        let folder = main.deletingLastPathComponent().standardizedFileURL
        let parent = folder.deletingLastPathComponent()
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard parent.path != folder.path, parent.path != home, parent.path != "/" else { return folder }
        let folderPath = normalized(folder) + "/"
        let parentPath = normalized(parent) + "/"
        let tree = includeTree(main: main, cache: cache, root: folder, fileManager: fileManager, limit: 500)
        func usesParent(_ node: IncludeNode) -> Bool {
            node.children.contains { child in
                if child.status == .ok, !child.isAbsolute, let url = child.url {
                    let path = normalized(url)
                    if !path.hasPrefix(folderPath) && path.hasPrefix(parentPath) { return true }
                }
                return usesParent(child)
            }
        }
        if usesParent(tree) { return parent }
        if normalized(main) == normalized(file), file.pathExtension.lowercased() != "ly",
           let names = try? fileManager.contentsOfDirectory(atPath: parent.path),
           names.contains(where: { $0.lowercased().hasSuffix(".ly") }) {
            return parent
        }
        return folder
    }

    /// A `.ly` in a folder next to `file`'s includes it, as `parts/flute.ly`
    /// includes `../music/notes.ly`. Reads at most 100 files.
    static func siblingIncludes(_ file: URL, cache: SourceCache, fileManager: FileManager) -> Bool {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        let parent = folder.deletingLastPathComponent()
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard parent.path != folder.path, parent.path != home, parent.path != "/",
              let siblings = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return false }
        let target = normalized(file)
        var budget = 100
        for sibling in siblings.sorted() where !sibling.hasPrefix(".") && sibling != folder.lastPathComponent {
            let directory = parent.appendingPathComponent(sibling)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".ly") {
                budget -= 1
                if budget < 0 { return false }
                let candidate = directory.appendingPathComponent(name)
                guard cache.text(candidate) != nil else { continue }
                let tree = includeTree(main: candidate, cache: cache, fileManager: fileManager, limit: 200)
                if paths(in: tree).contains(target) { return true }
            }
        }
        return false
    }

    // MARK: Loading

    /// The project `file` belongs to. `text` is the file's text if it differs
    /// from the disk (an open document).
    public static func open(_ file: URL, text: String? = nil, systemDirectories: [URL] = [],
                            read: @escaping Reader = diskReader, fileManager: FileManager = .default) -> LilyPondProject {
        let file = file.standardizedFileURL
        let cache = SourceCache(read: read)
        if let text { cache.set(text, for: file) }
        var problems: [ProjectProblem] = []

        var settings: ProjectSettings?
        let root: URL
        if let found = ProjectSettings.root(containing: file.deletingLastPathComponent(), fileManager: fileManager) {
            root = found
            do {
                settings = try ProjectSettings.load(root: found)
            } catch {
                settings = ProjectSettings()
                problems.append(ProjectProblem(severity: .error, message: "\(ProjectSettings.fileName) couldn't be read: \(describe(error))", file: found.appendingPathComponent(ProjectSettings.fileName), line: nil))
            }
        } else {
            root = guessRoot(for: file, cache: cache, fileManager: fileManager)
        }
        let settingsURL = root.appendingPathComponent(ProjectSettings.fileName)
        let includeDirectories = settings?.includeDirectories(root: root) ?? []
        for (path, url) in zip(settings?.includePaths ?? [], includeDirectories) {
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                problems.append(ProjectProblem(severity: .warning, message: "The include path \(path) isn't a folder.", file: settingsURL, line: nil))
            }
        }

        // Every .ly file's includes: what's used, and what's only content.
        let files = scanFolder(root, fileManager: fileManager)
        let sources = sourceFiles(in: files)
        let lyFiles = Array(sources.filter { $0.pathExtension.lowercased() == "ly" }.prefix(300))
        var trees: [String: IncludeNode] = [:]
        func tree(of main: URL, limit: Int = 1000) -> IncludeNode {
            if let known = trees[normalized(main)] { return known }
            let tree = includeTree(main: main, cache: cache, includeDirectories: includeDirectories,
                                   systemDirectories: systemDirectories, root: root, fileManager: fileManager,
                                   limit: limit)
            trees[normalized(main)] = tree
            return tree
        }
        var reachable: Set<String> = []
        var nested: Set<String> = []
        func collectNested(_ node: IncludeNode, parentNested: Bool) {
            for child in node.children where child.status == .ok {
                let isNested = parentNested || !child.isSection
                if isNested, let url = child.url { nested.insert(normalized(url)) }
                collectNested(child, parentNested: isNested)
            }
        }
        for ly in lyFiles {
            let lyTree = tree(of: ly)
            reachable.formUnion(paths(in: lyTree))
            collectNested(lyTree, parentNested: false)
        }

        // Makes output by itself or through the files it includes at top level.
        var outputs: [String: Bool] = [:]
        func producesOutput(_ source: URL, main: URL, visiting: Set<String> = []) -> Bool {
            let path = normalized(source)
            let key = path + "\u{0}" + normalized(main)
            if let known = outputs[key] { return known }
            guard let summary = cache.summary(source) else { return false }
            var result = summary.producesOutput
            for include in summary.includes where include.isSection && !result {
                let found = resolve(include.path, from: source, main: main, includeDirectories: includeDirectories,
                                    systemDirectories: systemDirectories, fileManager: fileManager)
                guard let url = found.url, !found.isSystem, !visiting.contains(normalized(url)) else { continue }
                result = producesOutput(url, main: main, visiting: visiting.union([path]))
            }
            outputs[key] = result
            return result
        }

        var targets: [URL] = []
        if let listed = settings?.targets {
            for path in listed {
                let url = ProjectSettings.url(path, root: root)
                if fileManager.fileExists(atPath: url.path) {
                    targets.append(url)
                } else {
                    problems.append(ProjectProblem(severity: .error, message: "\(ProjectSettings.fileName) lists the target \(path), which doesn't exist.", file: settingsURL, line: nil))
                }
            }
        } else {
            targets = lyFiles.filter { !nested.contains(normalized($0)) && producesOutput($0, main: $0) }
                .sorted { a, b in
                    let depthA = relativePath(a, to: root).split(separator: "/").count
                    let depthB = relativePath(b, to: root).split(separator: "/").count
                    if depthA != depthB { return depthA < depthB }
                    return relativePath(a, to: root).compare(relativePath(b, to: root),
                                                             options: [.numeric, .caseInsensitive]) == .orderedAscending
                }
        }

        // What ⌘R engraves for the file.
        let filePath = normalized(file)
        let fileText = cache.text(file) ?? ""
        var target: URL?
        if let own = targets.first(where: { normalized($0) == filePath }) {
            target = own
        } else if let master = DocumentVariables.master(for: file, text: fileText),
                  fileManager.fileExists(atPath: master.path) {
            target = master
        } else {
            let including = targets.filter { paths(in: tree(of: $0)).contains(filePath) }
            let preferred = settings?.defaultTarget.map { normalized(ProjectSettings.url($0, root: root)) }
            target = including.first { normalized($0) == preferred } ?? including.first
            if target == nil {
                let found = main(for: file, cache: cache, includeDirectories: includeDirectories, fileManager: fileManager)
                if normalized(found) != filePath {
                    target = found
                } else if LilyPondProject.sourceExtensions.contains(file.pathExtension.lowercased()),
                          producesOutput(file, main: file) {
                    target = file
                }
            }
        }

        let main = target ?? file
        trees[normalized(main)] = nil
        let mainTree = tree(of: main, limit: 3000)
        problems += treeProblems(mainTree, includer: main, root: root)
        if !(cache.text(main) ?? "").contains("\\version") {
            problems.append(ProjectProblem(severity: .hint, message: "\(main.lastPathComponent) has no \\version; convert-ly needs it to update the syntax later.", file: main, line: 1))
        }
        if target != nil { reachable.formUnion(paths(in: mainTree)) }
        // Include files nothing includes: not the main file, nor any other .ly
        // in the folder (such as parts).
        for source in sources where source.pathExtension.lowercased() != "ly" {
            if !reachable.contains(normalized(source)) {
                problems.append(ProjectProblem(severity: .hint, message: "\(relativePath(source, to: root)) isn't included by any .ly file.", file: source, line: nil))
            }
        }
        if target == nil && (file.pathExtension.lowercased() == "ly" || reachable.contains(filePath)) {
            problems.append(ProjectProblem(severity: .hint, message: "\(file.lastPathComponent) makes no output by itself (no \\score, music or \\markup at top level) and no target includes it, so there's nothing to engrave.", file: file, line: nil))
        }
        problems.sort { ($0.severity, $0.file.path, $0.line ?? 0) < ($1.severity, $1.file.path, $1.line ?? 0) }
        return LilyPondProject(file: file, main: main, root: root, settings: settings, targets: targets,
                               target: target, tree: mainTree, includedPaths: paths(in: mainTree), files: files,
                               problems: problems)
    }

    /// The project with `main` as the file it was opened for.
    public static func load(main: URL, mainText: String? = nil, systemDirectories: [URL] = [],
                            read: @escaping Reader = diskReader, fileManager: FileManager = .default) -> LilyPondProject {
        open(main, text: mainText, systemDirectories: systemDirectories, read: read, fileManager: fileManager)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context): return context.underlyingError?.localizedDescription ?? context.debugDescription
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default: return error.localizedDescription
        }
    }

    // MARK: Include tree

    /// Resolves an `\include` as LilyPond 2.26 does (relative-includes is on):
    /// relative to the including file, then to the main file's folder (the
    /// working directory), then the include paths (`-I`), then LilyPond's own
    /// `ly` folder.
    public static func resolve(_ written: String, from includer: URL, main: URL, includeDirectories: [URL] = [],
                               systemDirectories: [URL], fileManager: FileManager = .default)
        -> (url: URL?, isSystem: Bool, isFromIncludePath: Bool) {
        let expanded = (written as NSString).expandingTildeInPath
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            return (exists(url) ? url : nil, false, false)
        }
        for directory in [includer.deletingLastPathComponent(), main.deletingLastPathComponent()] {
            let url = directory.appendingPathComponent(expanded).standardizedFileURL
            if exists(url) { return (url, false, false) }
        }
        for directory in includeDirectories {
            let url = directory.appendingPathComponent(expanded).standardizedFileURL
            if exists(url) { return (url, false, true) }
        }
        for directory in systemDirectories {
            let url = directory.appendingPathComponent(expanded).standardizedFileURL
            if exists(url) { return (url, true, false) }
        }
        return (nil, false, false)
    }

    static func includeTree(main: URL, cache: SourceCache, includeDirectories: [URL] = [],
                            systemDirectories: [URL] = [], root: URL? = nil, fileManager: FileManager,
                            limit: Int = 3000) -> IncludeNode {
        let root = root ?? main.deletingLastPathComponent().standardizedFileURL
        let rootPath = normalized(root) + "/"
        var budget = limit
        func children(of file: URL, ancestors: [String], idPrefix: String) -> [IncludeNode] {
            guard let summary = cache.summary(file) else { return [] }
            return summary.includes.enumerated().map { index, include in
                budget -= 1
                let found = resolve(include.path, from: file, main: main, includeDirectories: includeDirectories,
                                    systemDirectories: systemDirectories, fileManager: fileManager)
                let expanded = (include.path as NSString).expandingTildeInPath
                var node = IncludeNode(
                    id: "\(idPrefix)/\(index):\(include.path)", written: include.path, url: found.url,
                    line: include.line, status: .ok, isAbsolute: expanded.hasPrefix("/"),
                    isOutsideProject: found.url.map { !found.isSystem && !normalized($0).hasPrefix(rootPath) } ?? false,
                    children: [])
                node.isFromIncludePath = found.isFromIncludePath
                node.isSection = include.isSection
                guard let url = found.url else {
                    node.status = .missing
                    return node
                }
                if found.isSystem {
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
                node.children = children(of: url, ancestors: ancestors + [path], idPrefix: node.id)
                return node
            }
        }
        let path = normalized(main)
        return IncludeNode(id: path, written: main.lastPathComponent, url: main, line: 0, status: .ok,
                           isAbsolute: false, isOutsideProject: false,
                           children: children(of: main, ancestors: [path], idPrefix: path))
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
                    problems.append(ProjectProblem(severity: .warning, message: "\(name) is included by an absolute path, so the project only builds on this computer. Copy it into the project, or add its folder to the project's include paths.", file: includer, line: child.line))
                } else if child.isOutsideProject && !child.isFromIncludePath {
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
