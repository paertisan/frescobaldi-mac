import AppKit
import FrescobaldiCore

/// The toolbar's target menu, like Xcode's scheme menu: what ⌘R engraves.
/// Choosing an entry only selects it; ⌘R (or the Engrave button) runs it.
final class TargetMenuController: NSObject, NSMenuDelegate {
    let button: NSPopUpButton
    private let model: ProjectModel
    private let documentName: () -> String
    /// Set by the window.
    var onShowSettings: (() -> Void)?

    init(model: ProjectModel, documentName: @escaping () -> String) {
        self.model = model
        self.documentName = documentName
        button = NSPopUpButton(frame: .zero, pullsDown: true)
        super.init()
        button.bezelStyle = .toolbar
        button.autoenablesItems = false
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        button.menu?.delegate = self
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        button.toolTip = "What ⌘R engraves"
        update()
    }

    /// Refreshes the button's title from the project and choice.
    func update() {
        let (title, symbol) = face()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        guard let menu = button.menu else { return }
        if menu.items.isEmpty { menu.addItem(item) } else { menu.items[0] = item }
        button.setTitle(title)
        button.synchronizeTitleAndSelectedItem()
        button.invalidateIntrinsicContentSize()
    }

    private func face() -> (String, String) {
        guard let project = model.project else { return (documentName(), "doc") }
        switch model.choice {
        case .automatic:
            guard let target = project.target else { return ("No Target", "exclamationmark.triangle") }
            return (project.relativePath(target), "music.note")
        case let .file(path):
            return (path, "music.note")
        case .all:
            return ("All Targets", "square.stack")
        case let .command(name):
            return ProjectModel.command(for: model.choice, in: project) == nil
                ? ("No Target", "exclamationmark.triangle") : (name, "terminal")
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = menu.items.first
        menu.removeAllItems()
        if let title { menu.addItem(title) }
        guard let project = model.project else {
            let item = NSMenuItem(title: "Save the document to choose a target", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let choice = model.choice

        let automatic = add(menu, "Automatic", .automatic, symbol: "wand.and.stars", checked: choice == .automatic)
        let automaticTarget = project.target.map { project.relativePath($0) }
        let explanation = automaticTarget.map { "Engraves \($0), the target of \(project.file.lastPathComponent)" }
            ?? "\(project.file.lastPathComponent) belongs to no target"
        automatic.toolTip = "The current file's target: itself, its master, or a target that includes it."
        if #available(macOS 14.4, *) { automatic.subtitle = explanation }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Targets"))
        if project.targets.isEmpty {
            let item = NSMenuItem(title: "No file here makes output by itself", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let defaultTarget = project.settings?.defaultTarget
        for target in project.targets {
            let path = project.relativePath(target)
            let item = add(menu, path, .file(path), symbol: "music.note", checked: choice == .file(path))
            item.toolTip = target.path
            if path == defaultTarget, #available(macOS 14.4, *) { item.subtitle = "Default target" }
        }
        if project.targets.count > 1 {
            add(menu, "All Targets (\(project.targets.count))", .all, symbol: "square.stack", checked: choice == .all)
        }
        if !project.commands.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Build Commands"))
            for command in project.commands {
                let item = add(menu, command.name, .command(command.name), symbol: "terminal",
                               checked: choice == .command(command.name))
                item.toolTip = command.command
                if #available(macOS 14.4, *) { item.subtitle = command.command }
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Project Settings…", action: #selector(showSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ choice: TargetChoice, symbol: String, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice.storage
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.state = checked ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let storage = sender.representedObject as? String else { return }
        model.choose(TargetChoice(storage: storage))
        update()
    }

    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }
}
