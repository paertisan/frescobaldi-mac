import AppKit
import FrescobaldiCore

/// The main menu, built in code. Actions go to the first responder unless a
/// target is set; DocumentWindowController (the window delegate) and
/// LilyTextView implement the app-specific ones.
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(delegate: delegate)))
        main.addItem(submenu(fileMenu(delegate: delegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(lilypondMenu()))
        main.addItem(submenu(toolsMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu(delegate: delegate)
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil,
                            tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    // MARK: Menus

    private static func appMenu(delegate: AppDelegate) -> NSMenu {
        let name = ProcessInfo.processInfo.processName == "Frescobaldi" ? "Frescobaldi" : ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        add(menu, "About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        add(menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        add(menu, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        let templates = NSMenuItem(title: "New from Template", action: nil, keyEquivalent: "")
        delegate.templatesMenu.delegate = delegate
        templates.submenu = delegate.templatesMenu
        menu.addItem(templates)
        add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        delegate.openRecentMenu.delegate = delegate
        recent.submenu = delegate.openRecentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "Save…", #selector(NSDocument.save(_:)), "s")
        add(menu, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
        add(menu, "Rename…", #selector(NSDocument.rename(_:)))
        add(menu, "Move To…", #selector(NSDocument.move(_:)))
        let revert = NSMenu(title: "Revert To")
        add(revert, "Last Saved Version", #selector(NSDocument.revertToSaved(_:)))
        add(revert, "Browse All Versions…", #selector(NSDocument.browseVersions(_:)))
        menu.addItem(submenu(revert))
        menu.addItem(.separator())
        add(menu, "Export PDF…", #selector(DocumentWindowController.exportPDF(_:)), "e", [.command, .shift])
        add(menu, "Show PDF in Finder", #selector(DocumentWindowController.revealPDF(_:)))
        menu.addItem(.separator())
        add(menu, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
        add(menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Delete", #selector(NSText.delete(_:)))
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        add(find, "Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(find, "Find and Replace…", finder, "f", [.command, .option],
            tag: NSTextFinder.Action.showReplaceInterface.rawValue)
        add(find, "Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
        add(find, "Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
        add(find, "Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
        add(find, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
        menu.addItem(submenu(find))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        // Source editing commands, implemented by LilyTextView.
        let menu = NSMenu(title: "Format")
        add(menu, "Toggle Comment", #selector(LilyTextView.toggleComment(_:)), "/")
        add(menu, "Shift Right", #selector(LilyTextView.shiftRight(_:)), "]")
        add(menu, "Shift Left", #selector(LilyTextView.shiftLeft(_:)), "[")
        menu.addItem(.separator())
        add(menu, "Go to Line…", #selector(LilyTextView.goToLine(_:)), "l")
        menu.addItem(.separator())
        add(menu, "Bigger", #selector(LilyTextView.makeFontBigger(_:)), "=", [.command, .option])
        add(menu, "Smaller", #selector(LilyTextView.makeFontSmaller(_:)), "-", [.command, .option])
        return menu
    }

    private static func lilypondMenu() -> NSMenu {
        let menu = NSMenu(title: "LilyPond")
        add(menu, "Engrave", #selector(DocumentWindowController.engravePreview(_:)), "r", symbol: "music.note")
        add(menu, "Engrave for Publishing", #selector(DocumentWindowController.engravePublish(_:)), "r",
            [.command, .shift])
        add(menu, "Stop Engraving", #selector(DocumentWindowController.stopEngraving(_:)), ".", symbol: "stop.fill")
        menu.addItem(.separator())
        add(menu, "Play MIDI", #selector(DocumentWindowController.toggleMIDI(_:)), "p", [.command, .option],
            symbol: "play.fill")
        menu.addItem(.separator())
        add(menu, "Next Issue", #selector(DocumentWindowController.nextIssue(_:)), "'")
        add(menu, "Previous Issue", #selector(DocumentWindowController.previousIssue(_:)), "'", [.command, .shift])
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        add(menu, "Transpose…", #selector(DocumentWindowController.transpose(_:)), "t", [.command, .control])
        let translate = NSMenu(title: "Translate Pitch Names")
        for language in LyEdit.languages {
            let item = add(translate, language.capitalized, #selector(DocumentWindowController.translatePitchNames(_:)))
            item.representedObject = language
        }
        menu.addItem(submenu(translate))
        menu.addItem(.separator())
        add(menu, "Relative to Absolute", #selector(DocumentWindowController.relativeToAbsolute(_:)))
        add(menu, "Absolute to Relative", #selector(DocumentWindowController.absoluteToRelative(_:)))
        add(menu, "Simplify Accidentals", #selector(DocumentWindowController.simplifyAccidentals(_:)))
        menu.addItem(.separator())
        add(menu, "Re-indent", #selector(DocumentWindowController.reindent(_:)), "i", [.command, .control])
        add(menu, "Reformat", #selector(DocumentWindowController.reformat(_:)))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        add(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        add(menu, "Show Log", #selector(DocumentWindowController.toggleLog(_:)), "y", [.command, .shift])
        add(menu, "Show Preview", #selector(DocumentWindowController.togglePreview(_:)), "\r", [.command, .option])
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(DocumentWindowController.zoomInPreview(_:)), "+")
        add(menu, "Zoom Out", #selector(DocumentWindowController.zoomOutPreview(_:)), "-")
        add(menu, "Fit Width", #selector(DocumentWindowController.zoomToFitPreview(_:)), "0")
        menu.addItem(.separator())
        add(menu, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        add(menu, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        add(menu, "LilyPond Documentation", #selector(AppDelegate.openLilyPondDocumentation(_:)), target: delegate)
        add(menu, "Frescobaldi Website", #selector(AppDelegate.openFrescobaldiWebsite(_:)), target: delegate)
        return menu
    }
}
