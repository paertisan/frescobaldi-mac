import AppKit
import FrescobaldiCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Version of the LilyPond found at launch (for templates and Settings).
    private(set) var lilypondVersion: LilyPondVersion?
    private var settingsWindowController: SettingsWindowController?
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
        #if DEBUG
        if AdjustSelfTest.isRequested {
            // In the background: don't take the user's focus.
            AdjustSelfTest.runIfRequested()
            return
        }
        #endif
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClaudeBridge.shared.stop()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        #if DEBUG
        if AdjustSelfTest.isRequested { return false }
        #endif
        return true
    }

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

    /// File > New Score…: the Score Wizard.
    @objc func newScore(_ sender: Any?) {
        ScoreWizardWindowController.show()
    }

    @objc func openLilyPondDocumentation(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://lilypond.org/doc/v2.26/Documentation/web/manuals")!)
    }

    @objc func openFrescobaldiWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://frescobaldi.org")!)
    }

    // MARK: Dynamic menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === templatesMenu {
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
