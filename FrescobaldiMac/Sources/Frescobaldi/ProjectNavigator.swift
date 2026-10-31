import AppKit
import Combine
import FrescobaldiCore
import SwiftUI

/// What ⌘R engraves in a project, chosen in the toolbar's target menu and
/// remembered per project folder (on this computer, not in the project).
enum TargetChoice: Equatable {
    /// The current file's own target: itself, its master, or what includes it.
    case automatic
    case file(String)
    case all
    /// A build command from frescobaldi.json, by name.
    case command(String)

    init(storage: String) {
        if storage == "all" { self = .all }
        else if storage.hasPrefix("file:") { self = .file(String(storage.dropFirst(5))) }
        else if storage.hasPrefix("command:") { self = .command(String(storage.dropFirst(8))) }
        else { self = .automatic }
    }

    var storage: String {
        switch self {
        case .automatic: "automatic"
        case let .file(path): "file:\(path)"
        case .all: "all"
        case let .command(name): "command:\(name)"
        }
    }
}

/// The project of the document in a window: its main file, the include
/// tree, the project folder, its targets and suggestions for organizing it.
final class ProjectModel: ObservableObject {
    @Published private(set) var project: LilyPondProject?
    /// The document has a file, so a project is on its way even while
    /// `project` is still nil.
    @Published private(set) var hasFile = false
    /// The window's own file, to mark it in the lists.
    @Published private(set) var currentPath: String?
    /// Expanded rows (include nodes and folders), kept across refreshes.
    @Published var expanded: Set<String> = []
    /// What ⌘R engraves, for this project folder.
    @Published private(set) var choice: TargetChoice = .automatic

    /// Set by the window: open a file, at a line if given.
    var onOpen: ((URL, Int?) -> Void)?
    /// Called on the main queue after each refresh.
    var onLoaded: ((LilyPondProject) -> Void)?
    /// Set by the window: engrave a target, or run a command, now.
    var onEngrave: ((TargetChoice) -> Void)?
    /// Set by the window: open the project settings.
    var onShowSettings: (() -> Void)?

    private var generation = 0
    /// No refresh is on its way, so `project` matches the open documents.
    private(set) var isUpToDate = false
    private let queue = DispatchQueue(label: "ProjectModel", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []

    static let choiceDidChange = Notification.Name("ProjectModelChoiceDidChange")
    private static let choicesKey = "projectTargetChoices"

    init() {
        // Another window of the same project chose a target.
        NotificationCenter.default.publisher(for: Self.choiceDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, note.object as AnyObject? !== self, let root = note.userInfo?["root"] as? String,
                      root == self.project.map({ LilyPondProject.normalized($0.root) }) else { return }
                self.choice = Self.storedChoice(root: root)
            }
            .store(in: &cancellables)
    }

    /// LilyPond's own `ly` folder, for includes such as english.ly.
    static var systemDirectories: [URL] {
        Preferences.lilypond().map { LilyPondLocator.includeDirectories(of: $0) } ?? []
    }

    /// Builds the project for `document` from the open documents' text
    /// (unsaved changes count) or the disk. Safe off the main thread.
    private static func loader(for document: LilyPondDocument) -> (() -> LilyPondProject)? {
        guard let url = document.fileURL else { return nil }
        var texts: [String: String] = [:]
        for case let open as LilyPondDocument in NSDocumentController.shared.documents {
            if let openURL = open.fileURL { texts[LilyPondProject.normalized(openURL)] = open.text }
        }
        let openTexts = texts
        let text = document.text
        let systemDirectories = Self.systemDirectories
        return {
            let read: LilyPondProject.Reader = { file in
                openTexts[LilyPondProject.normalized(file)] ?? LilyPondProject.diskReader(file)
            }
            return LilyPondProject.open(url, text: text, systemDirectories: systemDirectories, read: read)
        }
    }

    /// Rebuilds the project in the background.
    func refresh(document: LilyPondDocument) {
        generation += 1
        guard let load = Self.loader(for: document) else {
            project = nil
            currentPath = nil
            hasFile = false
            isUpToDate = true
            return
        }
        if !hasFile { hasFile = true }
        isUpToDate = false
        let generation = generation
        queue.async { [weak self] in
            let project = load()
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.apply(project)
            }
        }
    }

    /// The project as it is now, loading it right away if a refresh is
    /// still on its way (as when ⌘R follows an edit).
    func currentProject(for document: LilyPondDocument) -> LilyPondProject? {
        if isUpToDate { return project }
        guard let load = Self.loader(for: document) else { return nil }
        generation += 1
        apply(load())
        return project
    }

    private func apply(_ project: LilyPondProject) {
        if self.project?.main != project.main { expanded = [project.tree.id] }
        let root = LilyPondProject.normalized(project.root)
        if self.project.map({ LilyPondProject.normalized($0.root) }) != root {
            choice = Self.storedChoice(root: root)
        }
        self.project = project
        currentPath = LilyPondProject.normalized(project.file)
        isUpToDate = true
        onLoaded?(project)
    }

    // MARK: Targets

    private static func storedChoice(root: String) -> TargetChoice {
        let choices = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
        return TargetChoice(storage: choices[root] ?? "automatic")
    }

    /// Remembers the choice for the project and tells its other windows.
    func choose(_ choice: TargetChoice) {
        guard let project else { return }
        let root = LilyPondProject.normalized(project.root)
        var choices = UserDefaults.standard.dictionary(forKey: Self.choicesKey) as? [String: String] ?? [:]
        if choice == .automatic { choices.removeValue(forKey: root) } else { choices[root] = choice.storage }
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
        self.choice = choice
        NotificationCenter.default.post(name: Self.choiceDidChange, object: self, userInfo: ["root": root])
    }

    /// The files `choice` engraves in `project`. A chosen file that's gone
    /// falls back to the automatic target.
    static func targets(for choice: TargetChoice, in project: LilyPondProject) -> [URL] {
        switch choice {
        case .automatic, .command:
            return project.target.map { [$0] } ?? []
        case let .file(path):
            let url = ProjectSettings.url(path, root: project.root)
            guard FileManager.default.fileExists(atPath: url.path) else { return project.target.map { [$0] } ?? [] }
            return [url]
        case .all:
            return project.targets
        }
    }

    /// The command `choice` names, if it still exists.
    static func command(for choice: TargetChoice, in project: LilyPondProject) -> ProjectCommand? {
        guard case let .command(name) = choice else { return nil }
        return project.commands.first { $0.name == name }
    }

    /// What the current choice engraves, for display.
    var effectiveTargets: [URL] {
        project.map { Self.targets(for: choice, in: $0) } ?? []
    }

    func open(_ url: URL?, line: Int? = nil) {
        guard let url else { return }
        onOpen?(url, line)
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(id) },
                set: { if $0 { self.expanded.insert(id) } else { self.expanded.remove(id) } })
    }

    /// A sidebar section that starts expanded unless `expanded` is false.
    func section(_ name: String, expanded: Bool = true) -> Binding<Bool> {
        let id = "section:\(name)"
        guard expanded else { return binding(for: id) }
        let collapsed = binding(for: "collapsed-" + id)
        return Binding(get: { !collapsed.wrappedValue }, set: { collapsed.wrappedValue = !$0 })
    }
}

// MARK: - Sidebar

/// The sidebar: the document outline, or the project.
struct SidebarView: View {
    @ObservedObject var outline: OutlineModel
    @ObservedObject var project: ProjectModel
    @AppStorage("sidebarMode") private var mode = "outline"

    var body: some View {
        VStack(spacing: 0) {
            TextTabs(selection: $mode, tabs: [.init(value: "outline", title: "Outline"),
                                               .init(value: "project", title: "Project")])
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
            if mode == "project" {
                ProjectNavigatorView(model: project)
            } else {
                OutlineSidebarView(model: outline)
            }
        }
        .themedBackground()
    }
}

struct ProjectNavigatorView: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        if let project = model.project {
            List {
                // Suggestions start folded: the count in the header is enough
                // until you want to tidy up.
                if !project.problems.isEmpty {
                    Section(isExpanded: model.section("Suggestions", expanded: false)) {
                        ForEach(project.problems) { problem in
                            ProblemRow(problem: problem, root: project.root)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(problem.file, line: problem.line) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Suggestions")
                            Text("\(project.problems.count)")
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Section(isExpanded: model.section("Targets")) {
                    TargetsSection(project: project, model: model)
                } header: {
                    HStack {
                        Text("Targets")
                        Spacer()
                        Button { model.onShowSettings?() } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Project Settings…")
                    }
                }
                Section("Includes", isExpanded: model.section("Includes")) {
                    IncludeTreeRow(node: project.tree, project: project, model: model)
                }
                Section("Folder", isExpanded: model.section("Folder")) {
                    ForEach(project.files) { file in
                        FileTreeRow(file: file, project: project, model: model)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else if model.hasFile {
            // Loading: nothing rather than a message that's about to go.
            Color.clear
        } else {
            QuietEmptyState(title: "No Project", symbol: "folder",
                            message: "Save the document to see its includes and folder.")
        }
    }
}

/// The files to engrave, All Targets and the build commands, each with a
/// button that runs it now. The ones ⌘R runs are highlighted.
private struct TargetsSection: View {
    let project: LilyPondProject
    @ObservedObject var model: ProjectModel

    var body: some View {
        let active = Set(model.effectiveTargets.map(LilyPondProject.normalized))
        let defaultTarget = project.settings?.defaultTarget.map {
            LilyPondProject.normalized(ProjectSettings.url($0, root: project.root))
        }
        if project.targets.isEmpty {
            Text("No file here makes output by itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // Targets at the top of the project, then one collapsible group per
        // folder (parts/...), so many parts don't push the includes away.
        let groups = Dictionary(grouping: project.targets) { target -> String in
            let path = project.relativePath(target)
            return path.contains("/") ? (path as NSString).deletingLastPathComponent : ""
        }
        let folders = groups.keys.filter { !$0.isEmpty }.sorted {
            $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
        let row = { (target: URL, title: String) in
            let path = LilyPondProject.normalized(target)
            return TargetRow(title: title, symbol: "music.note",
                             isActive: model.choice != .all && !model.choice.isCommand && active.contains(path),
                             badge: path == defaultTarget ? "default" : nil,
                             help: target.path, open: { model.open(target) },
                             run: { model.onEngrave?(.file(project.relativePath(target))) })
        }
        ForEach(groups[""] ?? [], id: \.self) { target in
            row(target, project.relativePath(target))
        }
        ForEach(folders, id: \.self) { folder in
            let targets = groups[folder] ?? []
            DisclosureGroup(isExpanded: model.binding(for: "targets:\(folder)")) {
                ForEach(targets, id: \.self) { target in
                    row(target, target.lastPathComponent)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(folder)
                        .fontWeight(targets.contains { active.contains(LilyPondProject.normalized($0)) }
                                    && model.choice != .all && !model.choice.isCommand ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Badge("\(targets.count)")
                }
            }
        }
        if project.targets.count > 1 {
            TargetRow(title: "All Targets", symbol: "square.stack", isActive: model.choice == .all, badge: nil,
                      help: "Engrave all \(project.targets.count) targets", open: nil, runVerb: "Engrave",
                      run: { model.onEngrave?(.all) })
        }
        ForEach(project.commands) { command in
            TargetRow(title: command.name, symbol: "terminal", isActive: model.choice == .command(command.name),
                      badge: nil, help: command.command, open: nil, runVerb: "Run",
                      run: { model.onEngrave?(.command(command.name)) })
        }
    }
}

private struct TargetRow: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let badge: String?
    let help: String
    let open: (() -> Void)?
    var runVerb = "Engrave"
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(title)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let badge { Badge(badge) }
            // Shown on hover, so a long list of parts isn't a column of buttons.
            Button(action: run) {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("\(runVerb) \(title)")
            .accessibilityLabel("\(runVerb) \(title)")
            .modifier(RevealOnHover(hovering: hovering))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
        .help(help)
    }
}

extension TargetChoice {
    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}

/// An include and, in a disclosure group, what it includes.
private struct IncludeTreeRow: View {
    let node: IncludeNode
    let project: LilyPondProject
    @ObservedObject var model: ProjectModel

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: model.binding(for: node.id)) {
                ForEach(node.children) { child in
                    AnyView(IncludeTreeRow(node: child, project: project, model: model))
                }
            } label: {
                row
            }
        }
    }

    /// The root of the tree is what ⌘R engraves, unless nothing is.
    private var isMain: Bool { node.line == 0 && project.target != nil }
    private var isCurrent: Bool { node.url.map { LilyPondProject.normalized($0) == model.currentPath } ?? false }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: node.url ?? URL(fileURLWithPath: node.written)))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(node.written)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            badges
        }
        .opacity(node.status == .system ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.open(node.url) }
        .help(tooltip)
    }

    @ViewBuilder private var badges: some View {
        if isMain { Badge("main") }
        switch node.status {
        case .missing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cycle: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.red)
        case .system: Badge("LilyPond")
        case .truncated: Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        case .ok: EmptyView()
        }
        if node.isAbsolute {
            Image(systemName: "pin.fill").foregroundStyle(.orange)
        } else if node.isOutsideProject {
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
    }

    private var tooltip: String {
        var parts: [String] = []
        if let url = node.url { parts.append(url.path) }
        if node.line > 0 { parts.append("\\include on line \(node.line)") }
        switch node.status {
        case .missing: parts.append("Not found")
        case .cycle: parts.append("Includes itself")
        case .system: parts.append("Comes with LilyPond")
        case .truncated: parts.append("Not followed further")
        case .ok: break
        }
        if node.isAbsolute { parts.append("Absolute path: only builds on this computer") }
        else if node.isOutsideProject { parts.append("Outside the project folder") }
        return parts.joined(separator: "\n")
    }
}

private struct FileTreeRow: View {
    let file: ProjectFile
    let project: LilyPondProject
    @ObservedObject var model: ProjectModel

    var body: some View {
        if file.isDirectory {
            DisclosureGroup(isExpanded: model.binding(for: file.id)) {
                ForEach(file.children) { child in
                    AnyView(FileTreeRow(file: child, project: project, model: model))
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var path: String { LilyPondProject.normalized(file.url) }
    private var isSource: Bool { LilyPondProject.sourceExtensions.contains(file.url.pathExtension.lowercased()) }
    /// An include file nothing includes (as far as this project knows).
    private var isUnused: Bool {
        isSource && file.url.pathExtension.lowercased() != "ly" && !project.includedPaths.contains(path)
            && project.problems.contains { $0.file == file.url && $0.line == nil }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isDirectory ? "folder" : FileIcon.symbol(for: file.url))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(file.url.lastPathComponent)
                .fontWeight(path == model.currentPath ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if project.target != nil && path == LilyPondProject.normalized(project.main) { Badge("main") }
        }
        .opacity(isUnused || !(isSource || file.isDirectory) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !file.isDirectory { model.open(file.url) } }
        .help(isUnused ? "No .ly file includes this file." : file.url.path)
    }
}

private struct ProblemRow: View {
    let problem: ProjectProblem
    let root: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            mark
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(problem.message)
                    .font(.callout)
                    .lineLimit(4)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
    }

    private var location: String {
        let file = LilyPondProject.relativePath(problem.file, to: root)
        return problem.line.map { "\(file):\($0)" } ?? file
    }

    /// The error or warning symbol, or a light bulb for hints.
    @ViewBuilder private var mark: some View {
        switch problem.severity {
        case .error, .warning:
            SeverityMark(isError: problem.severity == .error)
        case .hint:
            Image(systemName: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ly": "music.note"
        case "ily", "lyi": "doc.text"
        case "pdf": "doc.richtext"
        case "mid", "midi": "pianokeys"
        case "scm": "function"
        case "png", "jpg", "jpeg", "svg": "photo"
        case "": "doc"
        default: "doc"
        }
    }
}
