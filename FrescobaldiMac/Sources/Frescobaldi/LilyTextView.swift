import AppKit
import FrescobaldiCore

/// The LilyPond source editor: an NSTextView on TextKit 1 with code-editor
/// behavior (auto-indent, soft tabs, comment toggling, line shifting).
final class LilyTextView: NSTextView {
    var indentWidth: Int { Preferences.indentWidth }

    /// Configures a plain-text code editor. Call once after creation.
    func configureForCode() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            // No Writing Tools button or rewrites in a code editor.
            writingToolsBehavior = .none
        }
        allowsCharacterPickerTouchBarItem = false
        usesFontPanel = false
        drawsBackground = true
        // Room between the line numbers and the text, and above the first line.
        textContainerInset = NSSize(width: 10, height: 12)
        applyStyle()
    }

    /// Font and theme colors. Call again when the settings change.
    func applyStyle() {
        let theme = EditorTheme.current
        font = EditorStyle.font
        backgroundColor = theme.background
        insertionPointColor = theme.insertionPoint
        var selected: [NSAttributedString.Key: Any] = [.backgroundColor: theme.selection]
        if let foreground = theme.selectionForeground { selected[.foregroundColor] = foreground }
        selectedTextAttributes = selected
        typingAttributes = EditorStyle.baseAttributes
        if let storage = textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: EditorStyle.font, range: all)
            storage.addAttribute(.foregroundColor, value: theme.foreground, range: all)
            storage.endEditing()
        }
        needsDisplay = true
    }

    /// Highlights the line with the insertion point, if the theme does.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        defer { drawTableColumns(in: rect) }
        guard let color = EditorTheme.current.currentLine, selectedRange().length == 0,
              let layoutManager else { return }
        let length = nsString.length
        let location = selectedRange().location
        var line: NSRect
        if length == 0 || (location >= length && layoutManager.extraLineFragmentTextContainer != nil) {
            line = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard line.height > 0 else { return }
        line.origin.x = 0
        line.origin.y += textContainerOrigin.y
        line.size.width = bounds.width
        color.setFill()
        line.intersection(rect).fill()
    }

    /// True while `replace` changes the text (not the user typing).
    private(set) var isReplacing = false

    /// One undoable replacement, selecting `selection` afterwards.
    func replace(_ range: NSRange, with replacement: String, selection: NSRange? = nil, actionName: String? = nil) {
        isReplacing = true
        defer { isReplacing = false }
        // Close the undo group right away instead of at the end of the event,
        // so the document counts the change at once: an engrave requested
        // right after (by Claude, say) must see it and save first.
        let undo = undoManager
        let ownGroup = undo.map { $0.groupsByEvent && $0.groupingLevel == 0 } ?? false
        if ownGroup {
            undo?.groupsByEvent = false
            undo?.beginUndoGrouping()
        }
        defer {
            if ownGroup {
                undo?.endUndoGrouping()
                undo?.groupsByEvent = true
            }
        }
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement,
                                                                           attributes: EditorStyle.baseAttributes))
        didChangeText()
        if let selection { setSelectedRange(selection) }
        if let actionName { undoManager?.setActionName(actionName) }
    }

    func apply(_ edit: TextEditing.Edit, actionName: String) {
        replace(edit.range, with: edit.replacement, selection: edit.selection, actionName: actionName)
    }

    var nsString: NSString { string as NSString }

    // MARK: Typing

    override func insertNewline(_ sender: Any?) {
        let location = selectedRange().location
        insertText(TextEditing.newlineInsertion(at: location, in: nsString, width: indentWidth),
                   replacementRange: selectedRange())
        scrollRangeToVisible(selectedRange())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typing `}` on a blank line removes one level of indentation.
        if let text = string as? String, text == "}", selectedRange().length == 0,
           replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           let dedent = TextEditing.dedentForClosing(at: selectedRange().location, in: nsString, width: indentWidth) {
            let range = NSRange(location: dedent.range.location, length: selectedRange().location - dedent.range.location)
            super.insertText(text, replacementRange: range)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Tab inserts spaces up to the next indentation stop; in a piano
    /// table it selects the next cell.
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if !nsString.substring(with: selection).contains("\n"),
           let cell = TableFormatter.cell(after: NSMaxRange(selection), in: nsString) {
            setSelectedRange(cell)
            scrollRangeToVisible(cell)
            return
        }
        if selection.length > 0 && nsString.substring(with: selection).contains("\n") {
            shiftRight(sender)
            return
        }
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        let count = indentWidth - column % indentWidth
        insertText(String(repeating: " ", count: count), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        let selection = selectedRange()
        if !nsString.substring(with: selection).contains("\n"),
           TableFormatter.table(containing: selection.location, in: nsString) != nil {
            if let cell = TableFormatter.cell(after: selection.location, backwards: true, in: nsString) {
                setSelectedRange(cell)
                scrollRangeToVisible(cell)
            }
            return
        }
        shiftLeft(sender)
    }

    /// Piano tables' `\col` as a thin bar (the highlighter hides the text).
    private func drawTableColumns(in rect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }
        let text = nsString
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x,
                                                                             dy: -textContainerOrigin.y), in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0, text.range(of: TableFormatter.marker, options: [], range: chars).location != NSNotFound
        else { return }
        EditorTheme.current.gutterText.withAlphaComponent(0.7).setFill()
        var search = chars
        while search.length > 0 {
            let found = text.range(of: TableFormatter.marker, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = NSMaxRange(found) < text.length ? text.character(at: NSMaxRange(found)) : 0x20
            let isWord = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
            // Only where the highlighter hid it (not in comments or strings).
            let hidden = (layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: found.location,
                                                           effectiveRange: nil) as? NSColor) == .clear
            if !isWord && hidden {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
                var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                box = box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                let width: CGFloat = 1.5
                NSRect(x: (box.midX - width / 2).rounded(), y: box.minY + 1, width: width, height: box.height - 2).fill()
            }
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(chars) - NSMaxRange(found))
        }
    }

    // MARK: Commands (Format menu)

    @objc func toggleComment(_ sender: Any?) {
        apply(TextEditing.toggleComment(selection: selectedRange(), in: nsString), actionName: "Toggle Comment")
    }

    @objc func shiftRight(_ sender: Any?) {
        apply(TextEditing.shift(selection: selectedRange(), in: nsString, right: true, width: indentWidth),
              actionName: "Shift Right")
    }

    @objc func shiftLeft(_ sender: Any?) {
        apply(TextEditing.shift(selection: selectedRange(), in: nsString, right: false, width: indentWidth),
              actionName: "Shift Left")
    }

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number, or line:column."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return }
            let link = TextEditLink(path: "", line: max(1, line), startColumn: max(0, (parts.count > 1 ? parts[1] : 1) - 1),
                                    endColumn: max(0, (parts.count > 1 ? parts[1] : 1) - 1))
            if let range = link.range(in: self.nsString) ?? TextLines.range(ofLine: 1, in: self.nsString) {
                self.reveal(NSRange(location: range.location, length: 0))
            }
        }
    }

    @objc func makeFontBigger(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func makeFontSmaller(_ sender: Any?) { changeFontSize(by: -1) }

    private func changeFontSize(by delta: Double) {
        let defaults = UserDefaults.standard
        let size = max(8, min(36, defaults.double(forKey: Preferences.Key.editorFontSize) + delta))
        defaults.set(size, forKey: Preferences.Key.editorFontSize)
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }

    /// Selects `range`, scrolls to it and flashes it.
    func reveal(_ range: NSRange, flash: Bool = true) {
        let length = (string as NSString).length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let target = range.length == 0 ? NSRange(location: min(range.location, length), length: 0) : clamped
        setSelectedRange(target)
        scrollRangeToVisible(target)
        if flash && target.length > 0 { showFindIndicator(for: target) }
        window?.makeFirstResponder(self)
    }
}
