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
        NSApp.activate()
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
