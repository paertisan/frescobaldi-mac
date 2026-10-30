import AppKit
import FrescobaldiCore

/// The source editor: a TextKit 1 text view sharing the document's text
/// storage, with line numbers and syntax highlighting.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    let document: LilyPondDocument
    let textView: LilyTextView
    private let scrollView = NSScrollView()
    private var ruler: LineNumberRuler!
    private var highlighter: SyntaxHighlighter!
    private(set) var lines = LineIndex()
    private var highlightScheduled = false
    private var observers: [NSObjectProtocol] = []

    /// Called (debounced) after the text changes.
    var onTextChange: (() -> Void)?
    /// Called when the insertion point moves.
    var onSelectionChange: ((NSRange) -> Void)?
    /// The file whose issue markers this editor shows: the document's, or
    /// the temporary copy an untitled document is engraved from.
    var issuePath: () -> String? = { nil } {
        didSet { refreshIssueMarkers() }
    }

    init(document: LilyPondDocument) {
        self.document = document
        // TextKit 1: build the stack by hand around the document's storage.
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        document.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = LilyTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let layoutManager = textView.layoutManager {
            document.textStorage.removeLayoutManager(layoutManager)
        }
    }

    override func loadView() {
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.configureForCode()
        textView.delegate = self

        scrollView.documentView = textView
        // Fill the visible height so clicks below the last line still hit the text view.
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        applyThemeToScrollView()
        scrollView.contentView.postsBoundsChangedNotifications = true

        ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.lineIndex = { [weak self] in self?.lines ?? LineIndex() }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = Preferences.showLineNumbers

        highlighter = SyntaxHighlighter(layoutManager: textView.layoutManager!, textStorage: document.textStorage)
        lines.rebuild(document.textStorage.string as NSString)
        ruler.updateThickness(lineCount: lines.lineCount)
        refreshIssueMarkers()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                            object: document.textStorage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.textStorageDidProcessEditing() }
        })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHighlight() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                            object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHighlight() }
        })
        observers.append(center.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        observers.append(center.addObserver(forName: IssueMarkerStore.didChange, object: nil, queue: nil) { [weak self] note in
            let paths = note.userInfo?["paths"] as? Set<String>
            MainActor.assumeIsolated {
                guard let self, let path = self.issuePath(), paths?.contains(IssueMarkers.key(path)) ?? true else { return }
                self.refreshIssueMarkers()
            }
        })
        // Pin the editor below the toolbar (the safe area) instead of relying
        // on automatic scroll insets, which a transparent titlebar breaks
        // (text scrolled under the title, e.g. after leaving full screen).
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleHighlight()
    }

    // MARK: Text changes

    private func textStorageDidProcessEditing() {
        let storage = document.textStorage
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let oldLines = lines
        lines.rebuild(storage.string as NSString)
        // Issue markers and messages move with the text (one editor per
        // text storage reports it).
        if !document.isLoading, let path = issuePath(), storage.layoutManagers.first === textView.layoutManager {
            IssueMarkerStore.shared.edited(path, LineEdit(location: edited.location,
                                                          oldLength: edited.length - storage.changeInLength,
                                                          newLength: edited.length, old: oldLines, new: lines))
        }
        if document.isLoading {
            highlighter.invalidateAll()
        } else {
            highlighter.invalidate(from: edited.location, lines: lines)
        }
        ruler.updateThickness(lineCount: lines.lineCount)
        ruler.needsDisplay = true
        // Layout isn't valid yet inside processEditing; color afterwards.
        scheduleHighlight()
        scheduleTextChangeCallback()
    }

    private func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.highlightScheduled = false
            self.highlightVisible()
        }
    }

    private func highlightVisible() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        var chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // A little margin so scrolling doesn't show uncolored lines.
        let margin = 2000
        let start = max(0, chars.location - margin)
        let end = min(document.textStorage.length, NSMaxRange(chars) + margin)
        chars = NSRange(location: start, length: end - start)
        highlighter.highlight(chars, lines: lines)
        ruler.needsDisplay = true
    }

    private var textChangeWork: DispatchWorkItem?
    private func scheduleTextChangeCallback() {
        textChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onTextChange?() }
        textChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func applyThemeToScrollView() {
        let theme = EditorTheme.current
        scrollView.backgroundColor = theme.background
        // Dark scrollers and find bar on a dark editor, also in a light window.
        scrollView.appearance = theme.isDark ? NSAppearance(named: .darkAqua) : nil
    }

    private func preferencesChanged() {
        textView.applyStyle()
        applyThemeToScrollView()
        highlighter.invalidateAll()
        scrollView.rulersVisible = Preferences.showLineNumbers
        ruler.updateThickness(lineCount: lines.lineCount)
        scheduleHighlight()
    }

    // MARK: NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        ruler.needsDisplay = true
        // The current-line highlight moves with the insertion point.
        if EditorTheme.current.currentLine != nil { textView.needsDisplay = true }
        onSelectionChange?(textView.selectedRange())
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    // MARK: API for the window

    /// Selects and shows a range.
    func select(_ range: NSRange) {
        textView.reveal(range)
    }

    /// Jumps to a point-and-click link or issue location in this document.
    func reveal(_ link: TextEditLink) {
        guard let range = link.range(in: textView.nsString) else { return }
        // Select the linked object; for a bare column, select up to the end of the word.
        var target = range
        if target.length == 0 {
            let lineEnd = NSMaxRange(lines.range(ofLine: min(link.line - 1, lines.lineCount - 1)))
            var end = target.location
            let text = textView.nsString
            while end < lineEnd, end < text.length,
                  let scalar = Unicode.Scalar(text.character(at: end)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end += 1
            }
            target.length = end - target.location
        }
        select(target)
    }

    /// Ruler markers for this file's issues from the last engrave that read it.
    private func refreshIssueMarkers() {
        guard ruler != nil else { return }
        ruler.issueMarkers = issuePath().map { IssueMarkerStore.shared.lines(for: $0) } ?? [:]
    }

    /// The insertion point as LilyPond's line (1-based) and column (scalar).
    var cursorPosition: (line: Int, column: Int) {
        TextEditLink.position(of: textView.selectedRange().location, in: textView.nsString)
    }
}
