import AppKit
import Combine
import FrescobaldiCore
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
    let midiPlayer = MIDIPlayer()

    private let mainSplit = NSSplitViewController()
    private let editorSplit = NestedSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var logItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var job: EngraveJob?
    /// The file LilyPond last engraved (the document, or a temp copy if untitled).
    private var engravedSource: URL?
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
        let sidebar = NSHostingController(rootView: OutlineSidebarView(model: outlineModel))
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
        }
        editor.onSelectionChange = { [weak self] _ in self?.highlightCursorInPreview() }
        outlineModel.update(text: lilyDocument.textStorage.string as NSString)
        outlineModel.onSelect = { [weak self] item in
            self?.editor.select(NSRange(location: item.range.location, length: 0))
            self?.editor.textView.showFindIndicator(for: item.range)
        }
        preview.onTextEditLink = { [weak self] link in self?.open(link) }
        engraveModel.onSelectMessage = { [weak self] message in self?.open(message.link) }
        engraveModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }
            .store(in: &cancellables)
        midiPlayer.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }
            .store(in: &cancellables)
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        lilyDocument.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        job?.cancel()
        midiPlayer.stop()
        try? FileManager.default.removeItem(at: untitledDirectory)
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let engrave = NSToolbarItem.Identifier("engrave")
        static let stop = NSToolbarItem.Identifier("stop")
        static let status = NSToolbarItem.Identifier("status")
        static let midi = NSToolbarItem.Identifier("midi")
        static let log = NSToolbarItem.Identifier("log")
        static let preview = NSToolbarItem.Identifier("preview")
        static let transpose = NSToolbarItem.Identifier("transpose")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "LilyPondDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.centeredItemIdentifiers = [ToolbarID.status]
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.engrave, ToolbarID.stop, .flexibleSpace,
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

    @objc func stopEngraving(_ sender: Any?) {
        job?.cancel()
    }

    func engrave(mode: EngraveJob.Mode, saveFirst: Bool = true) {
        job?.cancel()
        guard let lilypond = Preferences.lilypond() else {
            engraveModel.status = .failed("LilyPond not found")
            showLilyPondMissingAlert()
            return
        }
        if let url = lilyDocument.fileURL {
            if saveFirst && lilyDocument.isDocumentEdited {
                lilyDocument.isSavingForEngrave = true
                lilyDocument.save(to: url, ofType: lilyDocument.fileType ?? LilyPondType.source,
                                  for: .saveOperation) { [weak self] error in
                    guard let self else { return }
                    self.lilyDocument.isSavingForEngrave = false
                    if let error {
                        self.presentError(error)
                        return
                    }
                    self.run(lilypond: lilypond, source: url, mode: mode)
                }
            } else {
                run(lilypond: lilypond, source: url, mode: mode)
            }
        } else {
            // Untitled: engrave a temporary copy.
            do {
                try FileManager.default.createDirectory(at: untitledDirectory, withIntermediateDirectories: true)
                let name = lilyDocument.displayName.replacingOccurrences(of: "/", with: "-")
                let source = untitledDirectory.appendingPathComponent(name).appendingPathExtension("ly")
                try Data(lilyDocument.text.utf8).write(to: source)
                run(lilypond: lilypond, source: source, mode: mode)
            } catch {
                presentError(error)
            }
        }
    }

    private func run(lilypond: URL, source: URL, mode: EngraveJob.Mode) {
        let job = EngraveJob(lilypond: lilypond, source: source, mode: mode)
        self.job = job
        engravedSource = source
        engraveModel.status = .running(mode)
        engraveModel.log = ""
        do {
            try job.start(output: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.job === job else { return }
                    self.engraveModel.log += text
                }
            }, completion: { [weak self] result in
                DispatchQueue.main.async { self?.finish(job, result) }
            })
        } catch {
            self.job = nil
            engraveModel.status = .failed("Couldn't start LilyPond: \(error.localizedDescription)")
        }
    }

    private func finish(_ finishedJob: EngraveJob, _ result: EngraveJob.Result) {
        guard finishedJob === job else { return }
        job = nil
        engraveModel.log = result.log
        engraveModel.messages = result.messages
        issueIndex = -1
        if result.cancelled {
            engraveModel.status = .cancelled
        } else {
            engraveModel.status = .finished(succeeded: result.succeeded, errors: engraveModel.errorCount,
                                            warnings: engraveModel.warningCount, duration: result.duration)
        }
        editor.showIssues(result.messages, forPath: engravedSource?.path)

        let pdfs = result.pdfs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !pdfs.isEmpty { engraveModel.pdfs = pdfs }
        if !result.midis.isEmpty { engraveModel.midis = result.midis }
        if let pdf = pdfs.first {
            preview.load(pdf)
            if previewItem.isCollapsed { previewItem.animator().isCollapsed = false }
            highlightCursorInPreview()
        }
        if !result.cancelled && engraveModel.errorCount > 0 {
            engraveModel.selectedTab = .issues
            setLogVisible(true)
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
        preview.highlight(path: source.path, line: position.line, column: position.column)
    }

    @objc func nextIssue(_ sender: Any?) { stepIssue(by: 1) }
    @objc func previousIssue(_ sender: Any?) { stepIssue(by: -1) }

    private func stepIssue(by delta: Int) {
        let messages = engraveModel.messages
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

    /// Runs python-ly off the main thread, then applies the result as one
    /// undoable change.
    private func runLyEdit(_ edit: LyEdit, name: String) {
        guard let tool = AppResources.pythonLyTool else {
            let alert = NSAlert()
            alert.messageText = "python-ly isn't available"
            alert.informativeText = "The Tools menu needs Python 3 and the bundled python-ly. Install the Xcode Command Line Tools or Homebrew's python."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        let text = lilyDocument.text
        let selection = editor.textView.selectedRange()
        let indentWidth = Preferences.indentWidth
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try tool.apply(edit, to: text, selection: selection.length > 0 ? selection : nil,
                                                 indentWidth: indentWidth) }
            DispatchQueue.main.async {
                self?.applyLyResult(result, original: text, selection: selection, name: name)
            }
        }
    }

    private func applyLyResult(_ result: Result<String, Error>, original: String, selection: NSRange, name: String) {
        switch result {
        case let .failure(error):
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        case let .success(newText):
            // The user kept typing meanwhile: don't apply a stale result.
            guard lilyDocument.text == original else { NSSound.beep(); return }
            guard let change = TextReplacement.between(original, newText) else { return }
            let delta = (newText as NSString).length - (original as NSString).length
            let newSelection = selection.length > 0
                ? NSRange(location: selection.location, length: max(0, selection.length + delta))
                : NSRange(location: min(selection.location, (newText as NSString).length), length: 0)
            editor.textView.replace(change.range, with: change.replacement, selection: newSelection, actionName: name)
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
