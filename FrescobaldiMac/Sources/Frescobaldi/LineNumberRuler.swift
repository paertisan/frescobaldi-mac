import AppKit
import FrescobaldiCore

/// Line numbers in the editor's vertical ruler, with a colored dot on lines
/// that have errors or warnings from the last engrave.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Provided by the editor so the ruler doesn't rescan the text.
    var lineIndex: () -> LineIndex = { LineIndex() }
    /// 1-based line → most severe message on it.
    var issueMarkers: [Int: LilyPondMessage.Severity] = [:] {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 36
        // Since macOS 14 views don't clip by default, and the dirty rect can
        // reach past the ruler: without this the fill covers the text.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView?.font?.pointSize ?? 13) - 2), weight: .regular)
    }

    /// Widens the ruler for the number of digits.
    func updateThickness(lineCount: Int) {
        let digits = max(2, String(lineCount).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: numberFont]).width * CGFloat(digits)) + 16
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        (textView?.backgroundColor ?? .textBackgroundColor).setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let index = lineIndex()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let originY = textView.textContainerOrigin.y
        let theme = EditorTheme.current
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.gutterText]
        let currentLine = index.line(at: textView.selectedRange().location)
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.gutterCurrentText]

        func drawNumber(_ line: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let height = fragment.height
            let point = NSPoint(x: ruleThickness - size.width - 6, y: y + (height - size.height) / 2)
            label.draw(at: point, withAttributes: line == currentLine ? currentAttributes : attributes)
            if let severity = issueMarkers[line + 1] {
                let color: NSColor = severity.isError ? .systemRed : .systemYellow
                color.setFill()
                let dot = NSRect(x: 4, y: y + height / 2 - 3.5, width: 7, height: 7)
                NSBezierPath(ovalIn: dot).fill()
            }
        }

        var line = index.line(at: chars.location)
        while line < index.lineCount {
            let lineRange = index.range(ofLine: line)
            if lineRange.location > NSMaxRange(chars) { break }
            if lineRange.location >= text.length {
                // Empty last line after a final newline.
                if lineRange.location == text.length, line > 0 {
                    drawNumber(line, fragment: layoutManager.extraLineFragmentRect)
                }
                break
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(line, fragment: fragment)
            line += 1
        }
        if text.length == 0 {
            drawNumber(0, fragment: layoutManager.extraLineFragmentRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Click a number to select that line.
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y), in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        let index = lineIndex()
        let range = index.range(ofLine: index.line(at: location))
        textView.setSelectedRange(range)
        textView.window?.makeFirstResponder(textView)
    }
}
