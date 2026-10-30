import AppKit
import Combine
import FrescobaldiCore
import FrescobaldiMCP
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// One document window: outline sidebar | editor over a collapsible
/// issues/log panel | PDF preview. Also the window delegate, so it sits in
/// the responder chain for the LilyPond, Tools and View menu actions.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSToolbarItemValidation, NSMenuItemValidation {
    let lilyDocument: LilyPondDocument
    let editor: EditorViewController
    let preview = PreviewViewController()
    let engraveModel = EngraveModel()
    let outlineModel = OutlineModel()
    let projectModel = ProjectModel()
    let midiPlayer = MIDIPlayer()

    private let mainSplit = NSSplitViewController()
    private let editorSplit = NestedSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var logItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var run: EngraveRun?
    /// The file whose PDF the preview shows (the document, its target, or a
    /// temp copy if untitled).
    private var engravedSource: URL?
    private lazy var targetMenu = TargetMenuController(model: projectModel) { [weak self] in
        self?.lilyDocument.displayName ?? ""
    }
    private lazy var untitledDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Frescobaldi-\(UUID().uuidString)", isDirectory: true)
    private var issueIndex = -1
    private var logWasShown = false
    private var cancellables: Set<AnyCancellable> = []

    init(document: LilyPondDocument) {
        lilyDocument = document
        editor = EditorViewController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "LilyPondDocument"
        window.tabbingMode = .automatic
        window.minSize = NSSize(width: 640, height: 400)
        window.isRestorable = true
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()
        wireUp()
        // Centered unless a saved frame is restored. Only one window can own
        // the autosave name; later ones cascade.
        window.center()
        if !window.setFrameAutosaveName("LilyPondDocumentWindow") {
            if let key = NSApp.keyWindow {
                let topLeft = NSPoint(x: key.frame.minX, y: key.frame.maxY)
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
            } else {
                window.center()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildLayout() {
        // Hosting controllers in split panes must not size the window from
        // their SwiftUI content, or it shrinks to the panes' ideal heights.
        let sidebar = NSHostingController(rootView: SidebarView(outline: outlineModel, project: projectModel))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true

        editorSplit.splitView.isVertical = false
        editorSplit.splitView.dividerStyle = .thin
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 120
        editorItem.holdingPriority = .defaultLow
        let panel = NSHostingController(rootView: EngravePanelView(model: engraveModel))
        panel.sizingOptions = []
        logItem = NSSplitViewItem(viewController: panel)
        logItem.canCollapse = true
        logItem.minimumThickness = 90
        logItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        logItem.isCollapsed = true
        editorSplit.addSplitViewItem(editorItem)
        editorSplit.addSplitViewItem(logItem)
        editorSplit.splitView.autosaveName = "EditorSplit"

        let editorAreaItem = NSSplitViewItem(viewController: editorSplit)
        editorAreaItem.minimumThickness = 300
        previewItem = NSSplitViewItem(viewController: preview)
        previewItem.canCollapse = true
        previewItem.minimumThickness = 260

        mainSplit.splitView.dividerStyle = .thin
        mainSplit.addSplitViewItem(sidebarItem)
        mainSplit.addSplitViewItem(editorAreaItem)
        mainSplit.addSplitViewItem(previewItem)
        mainSplit.splitView.autosaveName = "MainSplit"
        window?.contentViewController = mainSplit
        window?.setContentSize(NSSize(width: 1280, height: 820))
    }

    private func wireUp() {
        editor.onTextChange = { [weak self] in
            guard let self else { return }
            self.outlineModel.update(text: self.lilyDocument.textStorage.string as NSString)
            self.projectModel.refresh(document: self.lilyDocument)
        }
        projectModel.onOpen = { [weak self] url, line in self?.openProjectFile(url, line: line) }
        projectModel.onEngrave = { [weak self] choice in self?.engrave(mode: .preview, choice: choice) }
        projectModel.onShowSettings = { [weak self] in self?.showProjectSettings(nil) }
        targetMenu.onShowSettings = { [weak self] in self?.showProjectSettings(nil) }
        projectModel.onLoaded = { [weak self] project in
            guard let self else { return }
            self.targetMenu.update()
            guard self.engraveModel.pdfs.isEmpty, self.engraveModel.status == .idle else { return }
            let targets = ProjectModel.targets(for: self.projectModel.choice, in: project)
            if let target = targets.first(where: { $0 == project.target }) ?? targets.first {
                self.showExistingOutput(for: target, in: project)
            }
        }
        projectModel.$choice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.targetMenu.update() } }
            .store(in: &cancellables)
        projectModel.refresh(document: lilyDocument)
        editor.onSelectionChange = { [weak self] _ in self?.highlightCursorInPreview() }
        outlineModel.update(text: lilyDocument.textStorage.string as NSString)
        outlineModel.onSelect = { [weak self] item in
            self?.editor.select(NSRange(location: item.range.location, length: 0))
            self?.editor.textView.showFindIndicator(for: item.range)
        }
        preview.onTextEditLink = { [weak self] link in self?.open(link) }
        engraveModel.onSelectMessage = { [weak self] message in
            // A message without a location is only in the log.
            if message.isLocated { self?.open(message.link) } else { self?.engraveModel.selectedTab = .log }
        }
        engraveModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }
            .store(in: &cancellables)
        midiPlayer.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Preferences.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)
        applyTheme()
    }

    /// The theme colors the whole window, not only the editor: dark themes
    /// get a dark appearance and their chrome color behind the toolbar.
    private func applyTheme() {
        let theme = EditorTheme.current
        window?.appearance = theme.appearance
        window?.titlebarAppearsTransparent = theme.chrome != nil
        window?.backgroundColor = theme.chrome ?? .windowBackgroundColor
        preview.applyTheme()
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        lilyDocument.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Other windows or apps may have changed the project's files.
        projectModel.refresh(document: lilyDocument)
    }

    func windowWillClose(_ notification: Notification) {
        run?.cancel()
        midiPlayer.stop()
        try? FileManager.default.removeItem(at: untitledDirectory)
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let engrave = NSToolbarItem.Identifier("engrave")
        static let target = NSToolbarItem.Identifier("target")
        static let stop = NSToolbarItem.Identifier("stop")
        static let status = NSToolbarItem.Identifier("status")
        static let midi = NSToolbarItem.Identifier("midi")
        static let log = NSToolbarItem.Identifier("log")
        static let preview = NSToolbarItem.Identifier("preview")
        static let transpose = NSToolbarItem.Identifier("transpose")
    }

    private func buildToolbar() {
        // A new identifier, so saved layouts from before the target menu reset.
        let toolbar = NSToolbar(identifier: "LilyPondDocumentToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.centeredItemIdentifiers = [ToolbarID.status]
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.engrave, ToolbarID.stop, ToolbarID.target, .flexibleSpace,
         ToolbarID.status, .flexibleSpace, ToolbarID.midi, ToolbarID.log, ToolbarID.preview]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ToolbarID.transpose, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = self
            item.isBordered = true
            return item
        }
        switch id {
        case ToolbarID.engrave:
            return button("Engrave", "music.note", #selector(engravePreview(_:)), "Engrave (⌘R)")
        case ToolbarID.stop:
            return button("Stop", "stop.fill", #selector(stopEngraving(_:)), "Stop Engraving (⌘.)")
        case ToolbarID.midi:
            return button("Play", "play.fill", #selector(toggleMIDI(_:)), "Play MIDI (⌥⌘P)")
        case ToolbarID.log:
            return button("Issues", "rectangle.bottomthird.inset.filled", #selector(toggleLog(_:)),
                          "Show or Hide Issues and Log (⇧⌘Y)")
        case ToolbarID.preview:
            return button("Preview", "sidebar.right", #selector(togglePreview(_:)), "Show or Hide Preview (⌥⌘↩)")
        case ToolbarID.transpose:
            return button("Transpose", "arrow.up.arrow.down", #selector(transposePitches(_:)), "Transpose (⌃⌘T)")
        case ToolbarID.target:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Target"
            item.paletteLabel = "Engrave Target"
            item.toolTip = "What ⌘R engraves"
            item.view = targetMenu.button
            item.visibilityPriority = .high
            return item
        case ToolbarID.status:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Status"
            item.paletteLabel = "Engrave Status"
            let hosting = NSHostingView(rootView: EngraveStatusView(model: engraveModel))
            hosting.sizingOptions = [.intrinsicContentSize]
            item.view = hosting
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarID.stop:
            return engraveModel.isRunning
        case ToolbarID.midi:
            item.image = NSImage(systemSymbolName: midiPlayer.isPlaying ? "stop.circle" : "play.fill",
                                 accessibilityDescription: midiPlayer.isPlaying ? "Stop" : "Play")
            item.label = midiPlayer.isPlaying ? "Stop" : "Play"
            return midiPlayer.isPlaying || !engraveModel.midis.isEmpty
        default:
            return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopEngraving(_:)):
            return engraveModel.isRunning
        case #selector(toggleMIDI(_:)):
            item.title = midiPlayer.isPlaying ? "Stop MIDI" : "Play MIDI"
            item.image = NSImage(systemSymbolName: midiPlayer.isPlaying ? "stop.fill" : "play.fill",
                                 accessibilityDescription: nil)
            return midiPlayer.isPlaying || !engraveModel.midis.isEmpty
        case #selector(exportPDF(_:)), #selector(revealPDF(_:)):
            return !engraveModel.pdfs.isEmpty
        case #selector(toggleLog(_:)):
            item.title = logItem.isCollapsed ? "Show Issues and Log" : "Hide Issues and Log"
            return true
        case #selector(togglePreview(_:)):
            item.title = previewItem.isCollapsed ? "Show Preview" : "Hide Preview"
            return true
        case #selector(engraveAllTargets(_:)):
            return (projectModel.project?.targets.count ?? 0) > 1
        case #selector(showProjectSettings(_:)):
            return lilyDocument.fileURL != nil
        case #selector(nextIssue(_:)), #selector(previousIssue(_:)):
            return !engraveModel.messages.isEmpty
        case #selector(zoomInPreview(_:)), #selector(zoomOutPreview(_:)), #selector(zoomToFitPreview(_:)):
            return preview.pdfView.document != nil
        default:
            return true
        }
    }

    // MARK: Engraving

    @objc func engravePreview(_ sender: Any?) { engrave(mode: .preview) }
    @objc func engravePublish(_ sender: Any?) { engrave(mode: .publish) }
    @objc func engraveAllTargets(_ sender: Any?) { engrave(mode: .preview, choice: .all) }

    @objc func stopEngraving(_ sender: Any?) {
        run?.cancel()
    }

    typealias EngraveCompletion = (Result<EngraveJob.Result, Error>) -> Void

    /// Engraves what the target menu says (or `choice`): the document's
    /// target, a chosen one, all of them, or a build command. With a
    /// completion (requests from Claude), problems are reported to it
    /// instead of in alerts, and the document's own target is engraved
    /// rather than all targets or a command.
    func engrave(mode: EngraveJob.Mode, saveFirst: Bool = true, choice requested: TargetChoice? = nil,
                 completion: EngraveCompletion? = nil) {
        run?.cancel()
        func fail(_ error: Error) {
            if let completion { completion(.failure(error)) } else { presentError(error) }
        }
        guard lilyDocument.fileURL != nil, let project = projectModel.currentProject(for: lilyDocument) else {
            // Untitled: engrave a temporary copy.
            guard let lilypond = requireLilyPond(completion) else { return }
            engraveModel.targetName = nil
            do {
                try FileManager.default.createDirectory(at: untitledDirectory, withIntermediateDirectories: true)
                let name = lilyDocument.displayName.replacingOccurrences(of: "/", with: "-")
                let source = untitledDirectory.appendingPathComponent(name).appendingPathExtension("ly")
                try Data(lilyDocument.text.utf8).write(to: source)
                start(EngraveRun(jobs: [EngraveJob(lilypond: lilypond, source: source, mode: mode)], names: [name]),
                      mode: mode, completion: completion)
            } catch {
                fail(error)
            }
            return
        }
        var choice = requested ?? projectModel.choice
        if completion != nil && requested == nil && (choice == .all || choice.isCommand) { choice = .automatic }
        if let command = ProjectModel.command(for: choice, in: project) {
            runCommand(command, in: project, saveFirst: saveFirst)
            return
        }
        let targets = ProjectModel.targets(for: choice, in: project)
        guard !targets.isEmpty else {
            engraveModel.status = .failed("Nothing to engrave")
            if let completion {
                completion(.failure(BridgeError(nothingToEngraveMessage(project))))
            } else {
                showNothingToEngrave(project)
            }
            return
        }
        guard let lilypond = requireLilyPond(completion) else { return }
        let jobs = targets.map { target in
            let options = project.engraveOptions(for: target)
            return EngraveJob(lilypond: lilypond, source: target, outputBase: options.outputBase, mode: mode,
                              extraArguments: options.arguments)
        }
        let names = targets.map { project.relativePath($0) }
        let current = project.target.map(LilyPondProject.normalized)
        let preferred = targets.firstIndex { LilyPondProject.normalized($0) == current } ?? 0
        let isSelf = targets.count == 1 && LilyPondProject.normalized(targets[0]) == LilyPondProject.normalized(project.file)
        engraveModel.targetName = isSelf || targets.count > 1 ? nil : names[0]
        // LilyPond reads the included files from disk, so save them all.
        save(saveFirst ? editedProjectDocuments(in: project) : []) { [weak self] error in
            guard let self else { return }
            if let error {
                fail(error)
                return
            }
            self.start(EngraveRun(jobs: jobs, names: names, preferred: preferred), mode: mode, completion: completion)
        }
    }

    private func requireLilyPond(_ completion: EngraveCompletion?) -> URL? {
        if let lilypond = Preferences.lilypond() { return lilypond }
        engraveModel.status = .failed("LilyPond not found")
        if let completion {
            completion(.failure(BridgeError("LilyPond wasn't found. Install it (brew install lilypond) or set its location in Frescobaldi's Settings.")))
        } else {
            showLilyPondMissingAlert()
        }
        return nil
    }

    private func nothingToEngraveMessage(_ project: LilyPondProject) -> String {
        "\(project.file.lastPathComponent) makes no output by itself (no \\score, music or \\markup at top level), and no target includes it."
    }

    /// ⌘R on an include file that nothing includes, or a .ly with only
    /// definitions: say why, and offer the project's main target.
    private func showNothingToEngrave(_ project: LilyPondProject) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Nothing to engrave"
        alert.informativeText = nothingToEngraveMessage(project) + """
             Include it from a .ly file, name the file to engrave with a master variable \
            (% -*- master: score.ly;), or choose a target in the toolbar.
            """
        let fallback = project.settings?.defaultTarget.map { ProjectSettings.url($0, root: project.root) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? project.targets.first
        if let fallback { alert.addButton(withTitle: "Engrave \(fallback.lastPathComponent)") }
        alert.addButton(withTitle: fallback == nil ? "OK" : "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let fallback, response == .alertFirstButtonReturn else { return }
            self?.engrave(mode: .preview, choice: .file(project.relativePath(fallback)))
        }
    }

    /// This document and the other open files of its project that have
    /// unsaved changes.
    private func editedProjectDocuments(in project: LilyPondProject) -> [LilyPondDocument] {
        let included = project.includedPaths
        let root = LilyPondProject.normalized(project.root) + "/"
        return NSDocumentController.shared.documents.compactMap { $0 as? LilyPondDocument }.filter { document in
            // An edit whose undo group is still open hasn't marked the document edited yet.
            let edited = document.isDocumentEdited || (document.undoManager?.groupingLevel ?? 0) > 0
            guard edited, let url = document.fileURL else { return false }
            if document === lilyDocument { return true }
            let path = LilyPondProject.normalized(url)
            return included.contains(path) || path.hasPrefix(root)
        }
    }

    /// Saves `documents` one after the other, then calls `completion`.
    private func save(_ documents: [LilyPondDocument], completion: @escaping (Error?) -> Void) {
        guard let document = documents.first, let url = document.fileURL else {
            completion(nil)
            return
        }
        document.isSavingForEngrave = true
        document.save(to: url, ofType: document.fileType ?? LilyPondType.source, for: .saveOperation) { [weak self] error in
            document.isSavingForEngrave = false
            if let error {
                completion(error)
            } else if let self {
                self.save(Array(documents.dropFirst()), completion: completion)
            }
        }
    }

    // MARK: Build commands

    /// Commands from frescobaldi.json that the user agreed to run, per project.
    private static let approvedCommandsKey = "approvedProjectCommands"

    static func approve(_ command: ProjectCommand, root: URL) {
        var approved = UserDefaults.standard.stringArray(forKey: approvedCommandsKey) ?? []
        let key = "\(LilyPondProject.normalized(root))\u{0}\(command.command)"
        if !approved.contains(key) { approved.append(key) }
        UserDefaults.standard.set(approved, forKey: approvedCommandsKey)
    }

    private static func isApproved(_ command: ProjectCommand, root: URL) -> Bool {
        let key = "\(LilyPondProject.normalized(root))\u{0}\(command.command)"
        return (UserDefaults.standard.stringArray(forKey: approvedCommandsKey) ?? []).contains(key)
    }

    /// Runs a build command. A project file can come from anyone, so its
    /// commands run only after the user has seen and allowed each one.
    private func runCommand(_ command: ProjectCommand, in project: LilyPondProject, saveFirst: Bool) {
        let directory = command.directory.map { ProjectSettings.url($0, root: project.root) } ?? project.root
        let go = { [weak self] in
            guard let self else { return }
            self.engraveModel.targetName = nil
            self.save(saveFirst ? self.editedProjectDocuments(in: project) : []) { error in
                if let error {
                    self.presentError(error)
                    return
                }
                let job = EngraveJob(command: command.command, directory: directory)
                self.start(EngraveRun(jobs: [job], names: [command.name], commandName: command.name, project: project),
                           mode: .preview, completion: nil)
            }
        }
        if Self.isApproved(command, root: project.root) {
            go()
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Run “\(command.name)”?"
        alert.informativeText = """
            \(ProjectSettings.fileName) in \(project.root.lastPathComponent) runs this in \(directory.path):

            \(command.command)

            Only run commands from projects you trust. Frescobaldi asks once per command.
            """
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        // Return cancels: running a stranger's command takes a deliberate click.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.approve(command, root: project.root)
            go()
        }
    }

    // MARK: Project settings

    /// The Project Settings sheet; saving writes frescobaldi.json at the
    /// project folder (only if something changed).
    @objc func showProjectSettings(_ sender: Any?) {
        guard let window, let project = projectModel.currentProject(for: lilyDocument) else {
            NSSound.beep()
            return
        }
        if let broken = project.problems.first(where: { $0.file == project.settingsURL && $0.severity == .error
                                                        && $0.message.contains("couldn't be read") }) {
            let alert = NSAlert()
            alert.messageText = "\(ProjectSettings.fileName) can't be edited here"
            alert.informativeText = broken.message + " Fix it in a text editor first."
            alert.addButton(withTitle: "Open File")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(project.settingsURL) }
            }
            return
        }
        var sheet: NSViewController?
        let close = { [weak self] in
            if let sheet { self?.contentViewController?.dismiss(sheet) }
        }
        let view = ProjectSettingsView(project: project, onSave: { [weak self] settings in
            guard let self else { return }
            let old = project.settings
            if settings != old && !(old == nil && settings.isEmpty) {
                do {
                    try settings.write(root: project.root)
                } catch {
                    self.presentError(error)
                    return
                }
                // The user wrote these commands, so they needn't confirm them.
                settings.commands.forEach { Self.approve($0, root: project.root) }
            }
            close()
            self.projectModel.refresh(document: self.lilyDocument)
        }, onCancel: close)
        let hosting = NSHostingController(rootView: view)
        sheet = hosting
        contentViewController?.presentAsSheet(hosting)
    }

    // MARK: Running

    private func start(_ run: EngraveRun, mode: EngraveJob.Mode, completion: EngraveCompletion?) {
        self.run = run
        if let completion { run.completions.append(completion) }
        engraveModel.status = .running(mode)
        engraveModel.progress = run.isSingle ? nil : (0, run.jobs.count)
        engraveModel.commandName = run.commandName
        engraveModel.log = ""
        // LilyPond uses one core; a few at a time for All Targets.
        let parallel = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        for _ in 0..<min(parallel, run.jobs.count) { startNext(run) }
    }

    private func startNext(_ run: EngraveRun) {
        guard !run.cancelled, run.started < run.jobs.count else { return }
        let index = run.started
        run.started += 1
        let job = run.jobs[index]
        do {
            try job.start(output: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.run === run, run.isSingle else { return }
                    self.engraveModel.log += text
                }
            }, completion: { [weak self] result in
                DispatchQueue.main.async { self?.jobFinished(run, index: index, result: result) }
            })
        } catch {
            let what = run.commandName.map { "run \($0)" } ?? "start LilyPond"
            jobFinished(run, index: index, result: EngraveJob.Result(
                exitStatus: -1, cancelled: false, log: "Couldn't \(what): \(error.localizedDescription)\n",
                messages: [], pdfs: [], midis: [], duration: 0))
        }
    }

    private func jobFinished(_ run: EngraveRun, index: Int, result: EngraveJob.Result) {
        run.results[index] = result
        if run.cancelled {
            // Jobs that never started count as stopped.
            for unstarted in run.started..<run.jobs.count {
                run.results[unstarted] = EngraveJob.Result(exitStatus: 0, cancelled: true, log: "", messages: [],
                                                           pdfs: [], midis: [], duration: 0)
            }
            run.started = run.jobs.count
        }
        if self.run === run && !run.isSingle {
            engraveModel.progress = (run.results.count, run.jobs.count)
            engraveModel.log = run.combined().log
        }
        if run.isFinished {
            finish(run)
        } else {
            startNext(run)
        }
    }

    private func finish(_ finishedRun: EngraveRun) {
        var result = finishedRun.combined()
        if let project = finishedRun.project { result = commandResult(result, in: project, since: finishedRun.begin) }
        // Whoever waits for this run gets its result, even if a newer one replaced it.
        for completion in finishedRun.completions { completion(.success(result)) }
        guard finishedRun === run else { return }
        run = nil
        engraveModel.log = result.log
        engraveModel.messages = result.messages
        issueIndex = -1
        if result.cancelled {
            engraveModel.status = .cancelled
        } else {
            engraveModel.status = .finished(succeeded: result.succeeded, errors: engraveModel.errorCount,
                                            warnings: engraveModel.warningCount, duration: result.duration)
        }
        // Markers for this document's own file, also when the main file was engraved.
        editor.showIssues(result.messages, forPath: lilyDocument.fileURL?.path ?? finishedRun.jobs.first?.source.path)
        projectModel.refresh(document: lilyDocument)

        let pdfs = result.pdfs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !pdfs.isEmpty { engraveModel.pdfs = pdfs }
        if !result.midis.isEmpty { engraveModel.midis = result.midis }
        if let pdf = pdfs.first {
            engravedSource = finishedRun.commandName == nil ? finishedRun.jobs[finishedRun.preferred].source
                : (projectModel.project?.target ?? lilyDocument.fileURL)
            preview.load(pdf)
            if previewItem.isCollapsed { previewItem.animator().isCollapsed = false }
            highlightCursorInPreview()
        }
        if !result.cancelled && engraveModel.errorCount > 0 {
            engraveModel.selectedTab = .issues
            setLogVisible(true)
        }
    }

    /// A build command's result, with messages that point at project files
    /// even when the command ran LilyPond somewhere else, and the PDF of
    /// the document's target first (or its existing PDF, if the log names
    /// none).
    private func commandResult(_ result: EngraveJob.Result, in project: LilyPondProject, since start: Date)
        -> EngraveJob.Result {
        var result = result
        let sources = Self.sourceFiles(in: project.files)
        // The log names output files relative to directories it may not
        // mention (Apple's make doesn't say where it goes): look for files of
        // that name the command wrote in the project.
        let fileManager = FileManager.default
        lazy var written: [URL] = Self.allFiles(in: LilyPondProject.scanFolder(project.root)).filter { url in
            let date = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return date.map { $0 >= start.addingTimeInterval(-1) } ?? false
        }
        func located(_ urls: [URL]) -> [URL] {
            urls.compactMap { url in
                if fileManager.fileExists(atPath: url.path) { return url }
                return written.first { $0.lastPathComponent == url.lastPathComponent }
            }
        }
        result.pdfs = located(result.pdfs)
        result.midis = located(result.midis)
        result.messages = result.messages.map { message in
            guard message.isLocated, !FileManager.default.fileExists(atPath: message.file) else { return message }
            let name = "/" + URL(fileURLWithPath: message.file).lastPathComponent
            let matches = sources.filter { $0.path.hasSuffix(name) }
            var message = message
            if matches.count == 1 { message.file = matches[0].path }
            return message
        }
        let target = project.target ?? project.targets.first
        if result.pdfs.isEmpty, let target {
            result.pdfs = EngraveJob.existingOutputs(for: target, outputDirectory: project.outputDirectory,
                                                     otherTargets: project.targets).pdfs
        }
        if let base = target?.deletingPathExtension().lastPathComponent,
           let index = result.pdfs.firstIndex(where: { $0.deletingPathExtension().lastPathComponent == base }) {
            result.pdfs.insert(result.pdfs.remove(at: index), at: 0)
        }
        return result
    }

    private static func allFiles(in files: [ProjectFile]) -> [URL] {
        files.flatMap { $0.isDirectory ? allFiles(in: $0.children) : [$0.url] }
    }

    private static func sourceFiles(in files: [ProjectFile]) -> [URL] {
        files.flatMap { file -> [URL] in
            if file.isDirectory { return sourceFiles(in: file.children) }
            return LilyPondProject.sourceExtensions.contains(file.url.pathExtension.lowercased()) ? [file.url] : []
        }
    }

    /// Shows the PDF from an earlier run, and enables Play for its MIDI, if
    /// they're at least as new as the document (as Frescobaldi does).
    private func showExistingOutput(for main: URL, in project: LilyPondProject) {
        let outputs = EngraveJob.existingOutputs(for: main, outputDirectory: project.outputDirectory,
                                                 otherTargets: project.targets)
        guard !outputs.pdfs.isEmpty || !outputs.midis.isEmpty else { return }
        engravedSource = main
        engraveModel.pdfs = outputs.pdfs
        engraveModel.midis = outputs.midis
        if let pdf = outputs.pdfs.first {
            preview.loadViewIfNeeded()
            preview.load(pdf)
        }
    }

    private func showLilyPondMissingAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "LilyPond wasn't found"
        alert.informativeText = "Install it with Homebrew (brew install lilypond) or choose its location in Settings."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { AppDelegate.shared.showSettings(nil) }
        }
    }

    // MARK: Point and click

    /// Opens a file from the project navigator: LilyPond files as a tab of
    /// this window (at `line` if given), anything else in its own app.
    func openProjectFile(_ url: URL, line: Int?) {
        let ext = url.pathExtension.lowercased()
        guard LilyPondProject.sourceExtensions.contains(ext) || ["scm", "txt"].contains(ext) else {
            NSWorkspace.shared.open(url)
            return
        }
        let reveal: (DocumentWindowController) -> Void = { controller in
            guard let line else { return }
            controller.editor.reveal(TextEditLink(path: url.path, line: line, startColumn: 0, endColumn: 0))
        }
        if let fileURL = lilyDocument.fileURL,
           LilyPondProject.normalized(fileURL) == LilyPondProject.normalized(url) {
            reveal(self)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] document, _, error in
            if let error {
                NSApp.presentError(error)
                return
            }
            guard let controller = (document as? LilyPondDocument)?.windowControllers.first as? DocumentWindowController,
                  let newWindow = controller.window else { return }
            if let window = self?.window, newWindow !== window, !(window.tabbedWindows?.contains(newWindow) ?? false) {
                window.addTabbedWindow(newWindow, ordered: .above)
            }
            newWindow.makeKeyAndOrderFront(nil)
            reveal(controller)
        }
    }

    /// Opens a source location: in this editor, or another (included) file.
    func open(_ link: TextEditLink) {
        if isThisDocument(link.path) {
            editor.reveal(link)
            return
        }
        let url = URL(fileURLWithPath: link.path)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error); return }
            guard let document = document as? LilyPondDocument else { return }
            for case let controller as DocumentWindowController in document.windowControllers {
                controller.editor.reveal(link)
            }
        }
    }

    private func isThisDocument(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        for candidate in [lilyDocument.fileURL, engravedSource].compactMap({ $0 }) {
            if candidate.standardizedFileURL.resolvingSymlinksInPath() == target { return true }
        }
        return false
    }

    private func highlightCursorInPreview() {
        guard preview.hasLinks, let source = engravedSource else { return }
        let position = editor.cursorPosition
        // The links point at the files the notes are in: this document's.
        let path = lilyDocument.fileURL?.path ?? source.path
        preview.highlight(path: path, line: position.line, column: position.column)
    }

    @objc func nextIssue(_ sender: Any?) { stepIssue(by: 1) }
    @objc func previousIssue(_ sender: Any?) { stepIssue(by: -1) }

    private func stepIssue(by delta: Int) {
        let messages = engraveModel.messages.filter(\.isLocated)
        guard !messages.isEmpty else { NSSound.beep(); return }
        issueIndex = (issueIndex + delta + messages.count) % messages.count
        open(messages[issueIndex].link)
    }

    // MARK: PDF

    @objc func exportPDF(_ sender: Any?) {
        guard let pdf = engraveModel.pdfs.first, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdf.lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: pdf, to: destination)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @objc func revealPDF(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(engraveModel.pdfs)
    }

    func previewPrintOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        preview.printOperation(printInfo: printInfo)
    }

    @objc func zoomInPreview(_ sender: Any?) { preview.zoomIn() }
    @objc func zoomOutPreview(_ sender: Any?) { preview.zoomOut() }
    @objc func zoomToFitPreview(_ sender: Any?) { preview.fitWidth() }

    // MARK: Panels

    @objc func toggleLog(_ sender: Any?) {
        setLogVisible(logItem.isCollapsed)
    }

    private func setLogVisible(_ visible: Bool) {
        guard logItem.isCollapsed == visible else { return }
        guard visible, !logWasShown else {
            logItem.animator().isCollapsed = !visible
            return
        }
        // The first time, the panel would open at its minimum height, which
        // shows only one issue. Give it about a third of the editor area.
        logWasShown = true
        logItem.isCollapsed = false
        let split = editorSplit.splitView
        split.layoutSubtreeIfNeeded()
        let wanted = min(260, max(logItem.minimumThickness, split.bounds.height * 0.3))
        if logItem.viewController.view.frame.height < wanted - 1 {
            split.setPosition(split.bounds.height - wanted - split.dividerThickness, ofDividerAt: 0)
        }
    }

    @objc func togglePreview(_ sender: Any?) {
        previewItem.animator().isCollapsed = !previewItem.isCollapsed
    }

    // MARK: MIDI

    @objc func toggleMIDI(_ sender: Any?) {
        if midiPlayer.isPlaying {
            midiPlayer.stop()
            return
        }
        guard let midi = engraveModel.midis.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            NSSound.beep()
            return
        }
        do {
            try midiPlayer.play(midi)
        } catch {
            presentError(error)
        }
    }

    // MARK: python-ly tools

    @objc func transposePitches(_ sender: Any?) {
        guard let window else { return }
        let defaults = UserDefaults.standard
        let alert = NSAlert()
        alert.messageText = "Transpose"
        alert.informativeText = """
            Transposes the selection, or the whole document if nothing is selected. \
            Write pitches in Dutch with octave marks, for example c and bes, or d'.
            """
        let from = NSTextField(string: defaults.string(forKey: "transposeFrom") ?? "c")
        let to = NSTextField(string: defaults.string(forKey: "transposeTo") ?? "d")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "From:"), from],
            [NSTextField(labelWithString: "To:"), to],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        from.widthAnchor.constraint(equalToConstant: 140).isActive = true
        to.widthAnchor.constraint(equalTo: from.widthAnchor).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Transpose")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = to
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let fromPitch = from.stringValue.trimmingCharacters(in: .whitespaces)
            let toPitch = to.stringValue.trimmingCharacters(in: .whitespaces)
            defaults.set(fromPitch, forKey: "transposeFrom")
            defaults.set(toPitch, forKey: "transposeTo")
            self?.runLyEdit(.transpose(from: fromPitch, to: toPitch), name: "Transpose")
        }
    }

    @objc func translatePitchNames(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else { return }
        runLyEdit(.translate(language: language), name: "Translate Pitch Names")
    }

    @objc func relativeToAbsolute(_ sender: Any?) { runLyEdit(.relativeToAbsolute, name: "Relative to Absolute") }
    @objc func absoluteToRelative(_ sender: Any?) { runLyEdit(.absoluteToRelative, name: "Absolute to Relative") }
    @objc func simplifyAccidentals(_ sender: Any?) { runLyEdit(.simplifyAccidentals, name: "Simplify Accidentals") }
    @objc func reindent(_ sender: Any?) { runLyEdit(.indent, name: "Re-indent") }
    @objc func reformat(_ sender: Any?) { runLyEdit(.reformat, name: "Reformat") }

    typealias LyEditCompletion = (Result<Bool, Error>) -> Void

    /// Runs python-ly off the main thread, then applies the result as one
    /// undoable change: to the selection, or everything if there is none or
    /// `wholeDocument` is set. A completion (requests from Claude) gets
    /// whether the text changed, or the error instead of an alert.
    func runLyEdit(_ edit: LyEdit, name: String, wholeDocument: Bool = false, completion: LyEditCompletion? = nil) {
        guard let tool = AppResources.pythonLyTool else {
            if let completion {
                completion(.failure(BridgeError("python-ly isn't available: Frescobaldi's Tools need Python 3.")))
                return
            }
            let alert = NSAlert()
            alert.messageText = "python-ly isn't available"
            alert.informativeText = "The Tools menu needs Python 3 and the bundled python-ly. Install the Xcode Command Line Tools or Homebrew's python."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        let text = lilyDocument.text
        let selection = editor.textView.selectedRange()
        let target = selection.length > 0 && !wholeDocument ? selection : nil
        let indentWidth = Preferences.indentWidth
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try tool.apply(edit, to: text, selection: target, indentWidth: indentWidth) }
            DispatchQueue.main.async {
                self?.applyLyResult(result, original: text, selection: selection, name: name, completion: completion)
            }
        }
    }

    private func applyLyResult(_ result: Result<String, Error>, original: String, selection: NSRange, name: String,
                               completion: LyEditCompletion?) {
        switch result {
        case let .failure(error):
            if let completion {
                completion(.failure(error))
            } else if let window {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        case let .success(newText):
            // The user kept typing meanwhile: don't apply a stale result.
            guard lilyDocument.text == original else {
                if let completion {
                    completion(.failure(BridgeError("The document changed while the tool ran; nothing was applied.")))
                } else {
                    NSSound.beep()
                }
                return
            }
            guard let change = TextReplacement.between(original, newText) else {
                completion?(.success(false))
                return
            }
            let delta = (newText as NSString).length - (original as NSString).length
            let newSelection = selection.length > 0
                ? NSRange(location: selection.location, length: max(0, selection.length + delta))
                : NSRange(location: min(selection.location, (newText as NSString).length), length: 0)
            editor.textView.replace(change.range, with: change.replacement, selection: newSelection, actionName: name)
            completion?(.success(true))
        }
    }
}

/// The editor/log split. It must not answer toggleSidebar: itself, or the
/// action would stop here instead of reaching the main split's sidebar.
private final class NestedSplitViewController: NSSplitViewController {
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSSplitViewController.toggleSidebar(_:)) { return false }
        return super.responds(to: selector)
    }
}

/// One press of ⌘R: a LilyPond job per target (a few run at a time), or a
/// build command.
private final class EngraveRun {
    let jobs: [EngraveJob]
    /// What each job engraves, for the log (target paths, or the command).
    let names: [String]
    /// The job whose PDF the preview shows: the document's own target.
    let preferred: Int
    let commandName: String?
    /// For build commands, to find the files their messages mean.
    let project: LilyPondProject?
    let begin = Date()
    var results: [Int: EngraveJob.Result] = [:]
    var started = 0
    var cancelled = false
    /// Waiting for the run to finish (Claude's engrave_document).
    var completions: [DocumentWindowController.EngraveCompletion] = []

    init(jobs: [EngraveJob], names: [String], preferred: Int = 0, commandName: String? = nil,
         project: LilyPondProject? = nil) {
        self.jobs = jobs
        self.names = names
        self.preferred = preferred
        self.commandName = commandName
        self.project = project
    }

    var isSingle: Bool { jobs.count == 1 }
    var isFinished: Bool { results.count == jobs.count }

    func cancel() {
        cancelled = true
        jobs.forEach { $0.cancel() }
    }

    /// The finished jobs as one result: their logs one after the other under
    /// a heading each, all their messages, and the preferred job's PDFs first.
    func combined() -> EngraveJob.Result {
        let finished = jobs.indices.compactMap { index in results[index].map { (index, $0) } }
        if isSingle, let only = finished.first?.1 { return only }
        var log = ""
        var messages: [LilyPondMessage] = []
        var pdfs: [URL] = []
        var midis: [URL] = []
        for (index, result) in finished where !(result.cancelled && result.log.isEmpty) {
            log += "──── \(names[index]) ────\n"
            let offset = log.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            messages += result.messages.map { message in
                var message = message
                message.logLine += offset
                return message
            }
            log += result.log.hasSuffix("\n") || result.log.isEmpty ? result.log : result.log + "\n"
            if index == preferred {
                pdfs.insert(contentsOf: result.pdfs, at: 0)
                midis.insert(contentsOf: result.midis, at: 0)
            } else {
                pdfs += result.pdfs
                midis += result.midis
            }
        }
        let results = finished.map(\.1)
        return EngraveJob.Result(
            exitStatus: results.first { $0.exitStatus != 0 }?.exitStatus ?? 0,
            cancelled: results.contains { $0.cancelled }, log: log, messages: messages, pdfs: pdfs, midis: midis,
            duration: Date().timeIntervalSince(begin))
    }
}
