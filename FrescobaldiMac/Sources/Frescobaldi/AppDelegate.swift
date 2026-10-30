import AppKit
import FrescobaldiCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Version of the LilyPond found at launch (for templates and Settings).
    private(set) var lilypondVersion: LilyPondVersion?
    private var settingsWindowController: SettingsWindowController?
    let openRecentMenu = NSMenu(title: "Open Recent")
    let templatesMenu = NSMenu(title: "New from Template")

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenu.build(delegate: self)
        // Window tabs: File > New Tab and the tab bar follow the system setting.
        NSWindow.allowsAutomaticWindowTabbing = true
        refreshLilyPondVersion()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeBridge.shared.update()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeBridge.shared.update() }
        }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClaudeBridge.shared.stop()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Re-detects LilyPond in the background (after launch and when Settings change).
    func refreshLilyPondVersion() {
        let setting = Preferences.lilypondPath
        DispatchQueue.global(qos: .utility).async {
            let version = LilyPondLocator.locate(userSetting: setting).flatMap { LilyPondLocator.version(of: $0) }
            DispatchQueue.main.async { self.lilypondVersion = version }
        }
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController() }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newFromTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? LilyPondTemplate else { return }
        (NSDocumentController.shared as? DocumentController)?.newDocument(from: template)
    }

    /// File > New Project: a folder with the score, a style sheet, and the
    /// music in one include file per instrument (see ProjectTemplate).
    @objc func newProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Creates a folder with the score, a style sheet, the music in one file per instrument, and the parts."
        panel.nameFieldLabel = "Project:"
        panel.nameFieldStringValue = "Untitled Project"
        panel.prompt = "Create"
        panel.canCreateDirectories = true

        let ensembles = NSPopUpButton(frame: .zero, pullsDown: false)
        ensembles.addItems(withTitles: ProjectTemplate.Ensemble.allCases.map(\.title))
        let label = NSTextField(labelWithString: "Instruments:")
        let accessory = NSStackView(views: [label, ensembles])
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = accessory

        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            let ensemble = ProjectTemplate.Ensemble.allCases[max(0, ensembles.indexOfSelectedItem)]
            self?.createProject(at: folder, ensemble: ensemble)
        }
    }

    private func createProject(at folder: URL, ensemble: ProjectTemplate.Ensemble) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: folder.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
                guard contents.filter({ !$0.hasPrefix(".") }).isEmpty else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
                        NSLocalizedDescriptionKey: "\"\(folder.lastPathComponent)\" already exists and isn't empty.",
                        NSLocalizedRecoverySuggestionErrorKey: "Choose another name for the project.",
                    ])
                }
            }
            let title = folder.lastPathComponent
            let paperSize = Locale.current.measurementSystem == .us ? "letter" : "a4"
            for (path, contents) in ProjectTemplate.files(title: title, ensemble: ensemble, version: lilypondVersion,
                                                         paperSize: paperSize) {
                let url = folder.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
            }
            // Show the new project's files.
            UserDefaults.standard.set("project", forKey: "sidebarMode")
            let main = folder.appendingPathComponent(ProjectTemplate.mainFileName(title: title))
            NSDocumentController.shared.openDocument(withContentsOf: main, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    @objc func openLilyPondDocumentation(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://lilypond.org/doc/v2.26/Documentation/web/manuals")!)
    }

    @objc func openFrescobaldiWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://frescobaldi.org")!)
    }

    // MARK: Dynamic menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            menu.removeAllItems()
            for url in NSDocumentController.shared.recentDocumentURLs {
                let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path),
                                      action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                item.toolTip = url.path
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Clear Menu",
                         action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        } else if menu === templatesMenu {
            menu.removeAllItems()
            let templates = LilyPondTemplate.templates(in: AppResources.templates)
            for template in templates {
                let item = NSMenuItem(title: template.name, action: #selector(newFromTemplate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = template
                menu.addItem(item)
            }
            if templates.isEmpty {
                let item = NSMenuItem(title: "No Templates", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
    }
}
