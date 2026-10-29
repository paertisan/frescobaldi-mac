import AppKit
import Combine
import FrescobaldiCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings window: toolbar-style tabs, each a SwiftUI form.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", view: GeneralSettingsView()))
        tabs.addTabViewItem(Self.tab("Editor", symbol: "character.cursor.ibeam", view: EditorSettingsView()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "General"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func tab<V: View>(_ label: String, symbol: String, view: V) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.frame(width: 520).fixedSize())
        controller.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// Detects LilyPond for the General tab.
final class LilyPondInfo: ObservableObject {
    @Published var executable: URL?
    @Published var version: LilyPondVersion?
    @Published var architectures: [MachOArchitecture] = []
    @Published var isChecking = false

    func refresh(setting: String) {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let executable = LilyPondLocator.locate(userSetting: setting)
            let version = executable.flatMap { LilyPondLocator.version(of: $0) }
            let architectures = executable.map { LilyPondLocator.architectures(of: $0) } ?? []
            DispatchQueue.main.async {
                self.executable = executable
                self.version = version
                self.architectures = architectures
                self.isChecking = false
            }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(Preferences.Key.lilypondPath) private var lilypondPath = ""
    @AppStorage(Preferences.Key.engraveOnSave) private var engraveOnSave = false
    @StateObject private var info = LilyPondInfo()

    var body: some View {
        Form {
            Section("LilyPond") {
                HStack {
                    TextField("Location", text: $lilypondPath, prompt: Text("Automatic"))
                        .onSubmit(changed)
                    Button("Choose…", action: choose)
                    if !lilypondPath.isEmpty {
                        Button("Automatic") {
                            lilypondPath = ""
                            changed()
                        }
                    }
                }
                LabeledContent("Found") {
                    if info.isChecking {
                        ProgressView().controlSize(.small)
                    } else if let executable = info.executable {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(info.version.map { "LilyPond \($0.description)" } ?? "LilyPond (unknown version)")
                                ArchitectureBadge(architectures: info.architectures)
                            }
                            Text(executable.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Not found. Install it with “brew install lilypond”.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Engraving") {
                Toggle("Engrave when saving", isOn: $engraveOnSave)
            }
        }
        .formStyle(.grouped)
        .onAppear { info.refresh(setting: lilypondPath) }
    }

    private func changed() {
        info.refresh(setting: lilypondPath)
        AppDelegate.shared.refreshLilyPondVersion()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the lilypond program or the folder containing it."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            lilypondPath = url.path
            changed()
        }
    }
}

/// "Apple silicon" or "Intel (Rosetta)" from the Mach-O header.
private struct ArchitectureBadge: View {
    let architectures: [MachOArchitecture]

    var body: some View {
        if architectures.contains(.arm64) {
            badge(architectures.contains(.x86_64) ? "Universal" : "Apple silicon", color: .green)
        } else if architectures.contains(.x86_64) {
            badge("Intel (Rosetta)", color: .orange)
                .help("This LilyPond runs under Rosetta. Homebrew’s lilypond in /opt/homebrew is native and faster.")
        } else if !architectures.isEmpty {
            badge("Unknown architecture", color: .gray)
        } else {
            badge("Script", color: .gray)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EditorSettingsView: View {
    @AppStorage(Preferences.Key.editorFontSize) private var fontSize = 13.0
    @AppStorage(Preferences.Key.indentWidth) private var indentWidth = 2
    @AppStorage(Preferences.Key.showLineNumbers) private var showLineNumbers = true

    var body: some View {
        Form {
            Section("Text") {
                Stepper(value: $fontSize, in: 8...36, step: 1) {
                    LabeledContent("Font size", value: "\(Int(fontSize)) pt")
                }
                Stepper(value: $indentWidth, in: 1...8) {
                    LabeledContent("Indent width", value: "\(indentWidth) spaces")
                }
                Toggle("Show line numbers", isOn: $showLineNumbers)
            }
        }
        .formStyle(.grouped)
        .onChange(of: fontSize) { notify() }
        .onChange(of: indentWidth) { notify() }
        .onChange(of: showLineNumbers) { notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }
}
