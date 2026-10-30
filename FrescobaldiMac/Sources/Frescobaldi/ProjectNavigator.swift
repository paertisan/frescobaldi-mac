import AppKit
import Combine
import FrescobaldiCore
import SwiftUI

/// The project of the document in a window: its main file, the include
/// tree, the project folder and suggestions for organizing it.
final class ProjectModel: ObservableObject {
    @Published private(set) var project: LilyPondProject?
    /// The file to engrave for this window's document.
    @Published private(set) var mainURL: URL?
    /// The window's own file, to mark it in the lists.
    @Published private(set) var currentPath: String?
    /// Expanded rows (include nodes and folders), kept across refreshes.
    @Published var expanded: Set<String> = []

    /// Set by the window: open a file, at a line if given.
    var onOpen: ((URL, Int?) -> Void)?
    /// Called on the main queue after each refresh.
    var onLoaded: ((LilyPondProject) -> Void)?

    private var generation = 0
    private let queue = DispatchQueue(label: "ProjectModel", qos: .utility)

    /// LilyPond's own `ly` folder, for includes such as english.ly.
    static var systemDirectories: [URL] {
        Preferences.lilypond().map { LilyPondLocator.includeDirectories(of: $0) } ?? []
    }

    /// Rebuilds the project in the background. Open documents' unsaved text
    /// counts instead of the file on disk.
    func refresh(document: LilyPondDocument) {
        guard let url = document.fileURL else {
            project = nil
            mainURL = nil
            currentPath = nil
            return
        }
        var texts: [String: String] = [:]
        for case let open as LilyPondDocument in NSDocumentController.shared.documents {
            if let openURL = open.fileURL { texts[LilyPondProject.normalized(openURL)] = open.text }
        }
        let openTexts = texts
        let text = document.text
        let systemDirectories = Self.systemDirectories
        generation += 1
        let generation = generation
        let current = LilyPondProject.normalized(url)
        queue.async { [weak self] in
            let read: LilyPondProject.Reader = { file in
                openTexts[LilyPondProject.normalized(file)] ?? LilyPondProject.diskReader(file)
            }
            let main = LilyPondProject.main(for: url, text: text, read: read)
            let project = LilyPondProject.load(main: main, systemDirectories: systemDirectories, read: read)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                if self.project?.main != project.main { self.expanded = [project.tree.id] }
                self.project = project
                self.mainURL = main
                self.currentPath = current
                self.onLoaded?(project)
            }
        }
    }

    func open(_ url: URL?, line: Int? = nil) {
        guard let url else { return }
        onOpen?(url, line)
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(id) },
                set: { if $0 { self.expanded.insert(id) } else { self.expanded.remove(id) } })
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
            Picker("Sidebar", selection: $mode) {
                Text("Outline").tag("outline")
                Text("Project").tag("project")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                if !project.problems.isEmpty {
                    Section("Suggestions") {
                        ForEach(project.problems) { problem in
                            ProblemRow(problem: problem, root: project.root)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(problem.file, line: problem.line) }
                        }
                    }
                }
                Section("Includes") {
                    IncludeTreeRow(node: project.tree, project: project, model: model)
                }
                Section("Folder") {
                    ForEach(project.files) { file in
                        FileTreeRow(file: file, project: project, model: model)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No Project", systemImage: "folder",
                                   description: Text("Save the document to see its includes and folder."))
                .frame(maxHeight: .infinity)
        }
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

    private var isMain: Bool { node.line == 0 }
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
                .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(file.url.lastPathComponent)
                .fontWeight(path == model.currentPath ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if path == LilyPondProject.normalized(project.main) { Badge("main") }
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
            Image(systemName: symbol)
                .foregroundStyle(color)
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

    private var symbol: String {
        switch problem.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .hint: "lightbulb"
        }
    }

    private var color: Color {
        switch problem.severity {
        case .error: .red
        case .warning: .orange
        case .hint: .secondary
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
