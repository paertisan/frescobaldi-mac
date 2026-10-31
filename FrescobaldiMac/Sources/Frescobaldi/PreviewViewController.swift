import AppKit
import Combine
import FrescobaldiCore
import PDFKit
import SwiftUI

/// Page and zoom state for the floating preview controls.
final class PreviewControlsModel: ObservableObject {
    @Published var hasDocument = false
    @Published var pageIndex = 0
    @Published var pageCount = 0
    @Published var scale: CGFloat = 1
    @Published var fitsWidth = true

    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fitWidth: () -> Void = {}
    var previousPage: () -> Void = {}
    var nextPage: () -> Void = {}
}

/// The engraved score: PDFKit with LilyPond point-and-click.
final class PreviewViewController: NSViewController, PDFViewDelegate {
    private struct LinkTarget {
        var page: Int
        var bounds: CGRect
    }

    let pdfView = ScoreView()
    let controls = PreviewControlsModel()
    private var emptyState: NSHostingView<PreviewEmptyState>!
    private var linkIndex = PointAndClickIndex<LinkTarget>()
    private var highlights: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var url: URL?

    /// Called when a textedit:// link in the score is clicked.
    var onTextEditLink: ((TextEditLink) -> Void)?

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let container = NSView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.delegate = self
        pdfView.onTextEditLink = { [weak self] url in
            if let link = TextEditLink(url: url) { self?.onTextEditLink?(link) }
        }
        container.addSubview(pdfView)

        emptyState = NSHostingView(rootView: PreviewEmptyState())
        emptyState.sizingOptions = []
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)

        let floating = NSHostingView(rootView: PreviewControls(model: controls))
        floating.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(floating)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            floating.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            floating.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container

        controls.zoomIn = { [weak self] in self?.zoomIn() }
        controls.zoomOut = { [weak self] in self?.zoomOut() }
        controls.fitWidth = { [weak self] in self?.fitWidth() }
        controls.previousPage = { [weak self] in self?.pdfView.goToPreviousPage(nil) }
        controls.nextPage = { [weak self] in self?.pdfView.goToNextPage(nil) }

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDocumentChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControls() }
            })
        }
        updateControls()
        applyTheme()
    }

    /// The area around the pages takes the theme's chrome color.
    func applyTheme() {
        pdfView.backgroundColor = EditorTheme.current.chrome ?? .underPageBackgroundColor
    }

    // MARK: Loading

    /// Shows `url`, keeping the page, scroll position and zoom of the
    /// previous PDF.
    func load(_ url: URL) {
        // Load from data: LilyPond rewrites the file on the next run, and a
        // mapped file shouldn't change underneath PDFKit.
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return }
        let previous = pdfView.document
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        var pageIndex = 0
        var point: CGPoint?
        if let previous, let destination = pdfView.currentDestination, let page = destination.page {
            pageIndex = previous.index(for: page)
            point = destination.point
        }

        clearHighlights()
        self.url = url
        pdfView.document = document
        buildLinkIndex(document)
        if autoScales {
            pdfView.autoScales = true
        } else {
            pdfView.scaleFactor = scale
        }
        if previous != nil, document.pageCount > 0, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            if let point {
                pdfView.go(to: PDFDestination(page: page, at: point))
            } else {
                pdfView.go(to: page)
            }
        }
        updateControls()
    }

    func clear() {
        url = nil
        pdfView.document = nil
        linkIndex = PointAndClickIndex()
        highlights = []
        updateControls()
    }

    private func buildLinkIndex(_ document: PDFDocument) {
        var index = PointAndClickIndex<LinkTarget>()
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            for annotation in page.annotations {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                if let url, let link = TextEditLink(url: url) {
                    index.add(link, LinkTarget(page: pageNumber, bounds: annotation.bounds))
                }
            }
        }
        linkIndex = index
    }

    var hasLinks: Bool { !linkIndex.isEmpty }

    // MARK: Point and click

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if let link = TextEditLink(url: url) {
            onTextEditLink?(link)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Highlights the notes that the editor position belongs to and scrolls
    /// them into view if needed.
    func highlight(path: String, line: Int, column: Int) {
        clearHighlights()
        guard let document = pdfView.document else { return }
        let targets = linkIndex.items(path: path, line: line, column: column)
        var firstVisible = false
        for (i, target) in targets.enumerated() {
            guard let page = document.page(at: target.page) else { continue }
            let rect = target.bounds.insetBy(dx: -1.5, dy: -1.5)
            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.color = .clear
            annotation.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
            annotation.shouldPrint = false
            page.addAnnotation(annotation)
            pdfView.annotationsChanged(on: page)
            highlights.append((page, annotation))
            if i == 0 {
                let inView = pdfView.convert(rect, from: page)
                firstVisible = pdfView.bounds.contains(inView)
                // Scroll with some margin, so the note doesn't end up at the edge.
                if !firstVisible { pdfView.go(to: rect.insetBy(dx: -40, dy: -40), on: page) }
            }
        }
    }

    func clearHighlights() {
        for (page, annotation) in highlights {
            page.removeAnnotation(annotation)
            pdfView.annotationsChanged(on: page)
        }
        highlights = []
    }

    // MARK: Zoom

    func zoomIn() {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.scaleFactor * 1.25, pdfView.maxScaleFactor)
    }

    func zoomOut() {
        pdfView.autoScales = false
        pdfView.scaleFactor = max(pdfView.scaleFactor / 1.25, pdfView.minScaleFactor)
    }

    func fitWidth() {
        pdfView.autoScales = true
    }

    private func updateControls() {
        let document = pdfView.document
        controls.hasDocument = document != nil
        controls.pageCount = document?.pageCount ?? 0
        if let document, let page = pdfView.currentPage {
            controls.pageIndex = document.index(for: page)
        } else {
            controls.pageIndex = 0
        }
        controls.scale = pdfView.scaleFactor
        controls.fitsWidth = pdfView.autoScales
        emptyState?.isHidden = document != nil
    }

    func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        guard let document = pdfView.document else { return nil }
        return document.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true)
    }
}

/// A PDFView that handles clicks on LilyPond's textedit:// links itself.
/// PDFKit on macOS 27 doesn't call pdfViewWillClick(onLink:with:) for them,
/// and the cursor highlight boxes would cover them anyway. PDFKit sends mouse
/// events to its internal subviews, so hitTest claims the points over links.
final class ScoreView: PDFView {
    var onTextEditLink: ((URL) -> Void)?
    private var linkTracking: NSTrackingArea?

    /// The textedit:// link under a point in this view's coordinates.
    func textEditURL(at point: NSPoint) -> URL? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() where annotation.bounds.contains(pagePoint) {
            if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url, url.scheme == "textedit" {
                return url
            }
        }
        return nil
    }

    private func textEditURL(for event: NSEvent) -> URL? {
        textEditURL(at: convert(event.locationInWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), document != nil, textEditURL(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let url = textEditURL(for: event), let window else {
            return super.mouseDown(with: event)
        }
        // Track the click here: PDFKit's gesture handling swallows the mouse-up.
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if textEditURL(for: next) == url { onTextEditLink?(url) }
                return
            }
        }
    }

    // A pointing hand over notes, like a link in a browser.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if textEditURL(for: event) != nil { NSCursor.pointingHand.set() }
    }
}

// MARK: - SwiftUI pieces

struct PreviewEmptyState: View {
    var body: some View {
        QuietEmptyState(title: "No Preview", symbol: "music.note",
                        message: "Engrave the document (⌘R) to see the score here.")
        .themedBackground(fallback: Color(nsColor: .underPageBackgroundColor))
    }
}

struct PreviewControls: View {
    @ObservedObject var model: PreviewControlsModel

    var body: some View {
        if model.hasDocument {
            HStack(spacing: 12) {
                Button(action: model.previousPage) { Image(systemName: "chevron.up").accessibilityLabel("Previous Page") }
                    .disabled(model.pageIndex == 0)
                    .help("Previous Page")
                Text("\(model.pageIndex + 1) of \(model.pageCount)")
                    .monospacedDigit()
                    .frame(minWidth: 52)
                Button(action: model.nextPage) { Image(systemName: "chevron.down").accessibilityLabel("Next Page") }
                    .disabled(model.pageIndex + 1 >= model.pageCount)
                    .help("Next Page")
                Divider().frame(height: 16)
                Button(action: model.zoomOut) { Image(systemName: "minus.magnifyingglass").accessibilityLabel("Zoom Out") }
                    .help("Zoom Out")
                Text("\(Int((model.scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
                Button(action: model.zoomIn) { Image(systemName: "plus.magnifyingglass").accessibilityLabel("Zoom In") }
                    .help("Zoom In")
                Button(action: model.fitWidth) { Image(systemName: "arrow.left.and.right").accessibilityLabel("Fit Width") }
                    .disabled(model.fitsWidth)
                    .help("Fit Width")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .modifier(FloatingBackground())
        }
    }
}

/// Liquid Glass on macOS 26 and later, a material capsule before.
private struct FloatingBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}
