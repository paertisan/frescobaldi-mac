import AppKit
import FrescobaldiCore
import SwiftUI

/// The sheet behind Project Settings…: targets, include paths, output
/// folder and build commands, saved in the project's frescobaldi.json.
struct ProjectSettingsView: View {
    let project: LilyPondProject
    /// Every .ly file in the project, relative to its folder.
    let candidates: [String]
    let onSave: (ProjectSettings) -> Void
    let onCancel: () -> Void

    @State private var findTargets: Bool
    @State private var chosen: Set<String>
    @State private var defaultTarget: String
    @State private var includePaths: [String]
    @State private var outputDirectory: String
    @State private var commands: [EditableCommand]

    struct EditableCommand: Identifiable {
        let id = UUID()
        var name: String
        var command: String
        var directory: String
    }

    init(project: LilyPondProject, onSave: @escaping (ProjectSettings) -> Void, onCancel: @escaping () -> Void) {
        self.project = project
        self.onSave = onSave
        self.onCancel = onCancel
        func lyFiles(_ files: [ProjectFile]) -> [URL] {
            files.flatMap { $0.isDirectory ? lyFiles($0.children) : ($0.url.pathExtension.lowercased() == "ly" ? [$0.url] : []) }
        }
        let found = project.targets.map { project.relativePath($0) }
        var all = found
        for file in lyFiles(project.files) where !all.contains(project.relativePath(file)) {
            all.append(project.relativePath(file))
        }
        candidates = all
        let settings = project.settings ?? ProjectSettings()
        _findTargets = State(initialValue: settings.targets == nil)
        _chosen = State(initialValue: Set(settings.targets ?? found))
        _defaultTarget = State(initialValue: settings.defaultTarget ?? "")
        _includePaths = State(initialValue: settings.includePaths)
        _outputDirectory = State(initialValue: settings.outputDirectory ?? "")
        _commands = State(initialValue: settings.commands.map {
            EditableCommand(name: $0.name, command: $0.command, directory: $0.directory ?? "")
        })
    }

    /// Targets as they'll be saved, in the order of `candidates`.
    private var targetList: [String] { candidates.filter(chosen.contains) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Find targets automatically", isOn: $findTargets)
                    if findTargets {
                        Text("Every .ly file that makes output by itself (a \\score, \\book, music or \\markup at top level) and isn't used inside another file's music.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates, id: \.self) { path in
                            Toggle(path, isOn: Binding(
                                get: { chosen.contains(path) },
                                set: { if $0 { chosen.insert(path) } else { chosen.remove(path) } }))
                        }
                    }
                    Picker("Default target", selection: $defaultTarget) {
                        Text("None").tag("")
                        ForEach(findTargets ? project.targets.map { project.relativePath($0) } : targetList, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } header: {
                    Text("Targets")
                } footer: {
                    Text("⌘R engraves the current file's target. For a file that several targets include, that's the default target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(includePaths.indices, id: \.self) { index in
                        HStack {
                            TextField("Folder", text: $includePaths[index], prompt: Text("../openlilylib"))
                                .labelsHidden()
                            Button {
                                includePaths.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                    Button("Add Folder…") { chooseFolder { includePaths.append($0) } }
                } header: {
                    Text("Include Paths")
                } footer: {
                    Text("Folders LilyPond searches for \\include files (-I), relative to the project folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("Output folder", text: $outputDirectory, prompt: Text("Next to each file"))
                            .labelsHidden()
                        Button("Choose…") { chooseFolder(create: true) { outputDirectory = $0 } }
                    }
                } header: {
                    Text("Output Folder")
                } footer: {
                    Text("Where PDF and MIDI files go, such as build or pdf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach($commands) { $command in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Name", text: $command.name, prompt: Text("Name, such as Parts"))
                                    .labelsHidden()
                                Button {
                                    commands.removeAll { $0.id == command.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                            TextField("Command", text: $command.command, prompt: Text("make parts"))
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                            TextField("Folder", text: $command.directory, prompt: Text("Folder (the project folder if empty)"))
                                .labelsHidden()
                                .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Add Command") { commands.append(EditableCommand(name: "", command: "", directory: "")) }
                } header: {
                    Text("Build Commands")
                } footer: {
                    Text("Run with /bin/sh from the target menu. LilyPond's errors in their output show up as issues, and the PDF reloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Saved in \(ProjectSettings.fileName) in \(project.root.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.settingsURL.path)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(settings) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }

    private var settings: ProjectSettings {
        let trimmedPaths = includePaths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let output = outputDirectory.trimmingCharacters(in: .whitespaces)
        let commandList = commands.compactMap { command -> ProjectCommand? in
            let text = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let name = command.name.trimmingCharacters(in: .whitespaces)
            let directory = command.directory.trimmingCharacters(in: .whitespaces)
            return ProjectCommand(name: name.isEmpty ? text : name, command: text,
                                  directory: directory.isEmpty ? nil : directory)
        }
        let targets = findTargets ? nil : targetList
        let defaultTarget = targets.map { $0.contains(defaultTarget) } ?? true ? defaultTarget : ""
        return ProjectSettings(targets: targets, defaultTarget: defaultTarget.isEmpty ? nil : defaultTarget,
                               includePaths: trimmedPaths, outputDirectory: output.isEmpty ? nil : output,
                               commands: commandList)
    }

    private func chooseFolder(create: Bool = false, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = create
        panel.directoryURL = project.root
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(ProjectSettings.portablePath(for: url, root: project.root))
    }
}
