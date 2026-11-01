import AppKit
import FrescobaldiCore
import PDFKit

/// An object in the preview that can be dragged, and where it is.
struct AdjustItem {
    var link: GrobLink
    var page: Int
    /// The link's rectangle in page coordinates.
    var bounds: CGRect

    /// A handle (control point, beam end) in page coordinates.
    func handle(_ index: Int) -> CGPoint {
        let offset = link.handles[index]
        return CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y)
    }
}

/// What a plain drag changes, per grob type, chosen with right-click.
/// Kept for the session only.
@MainActor enum AdjustChoices {
    static var properties: [String: AdjustProperty] = [:]

    static func property(for link: GrobLink) -> AdjustProperty? {
        if let chosen = properties[link.grob], link.properties.contains(chosen) { return chosen }
        return link.properties.first
    }
}

/// Lies over the PDF view. While adjusting (the toolbar's Adjust, or ⌥
/// held) it outlines the object under the pointer and lets it be dragged;
/// everywhere else it lets events through to the PDF view.
final class AdjustOverlay: NSView, NSViewToolTipOwner {
    weak var pdfView: PDFView?
    /// Objects per page index.
    var items: [Int: [AdjustItem]] = [:] {
        didSet {
            pending = nil
            refreshHover()
        }
    }
    var isOn = false { didSet { if isOn != oldValue { refreshHover() } } }
    var optionHeld = false { didSet { if optionHeld != oldValue { refreshHover() } } }
    var isActive: Bool { (isOn || optionHeld) && !items.isEmpty }
    var hasItems: Bool { !items.isEmpty }

    /// A finished drag: apply `tweak`, then call back whether it worked.
    var onAdjust: ((AdjustItem, Tweak, @escaping (Bool) -> Void) -> Void)?
    /// A click on an object without dragging: show it in the source.
    var onReveal: ((GrobLink) -> Void)?
    /// Tooltip text for an object.
    var describe: ((GrobLink) -> String)?

    private struct Drag {
        var item: AdjustItem
        var handle: Int?
        /// In page coordinates.
        var delta = CGPoint.zero
        var image: NSImage?
    }

    private var hovered: (item: AdjustItem, handle: Int?)?
    private var drag: Drag?
    /// A dropped drag, shown where it went until the new PDF arrives.
    private var pending: Drag?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    private var accent: NSColor { EditorTheme.current.accent ?? .controlAccentColor }

    // MARK: Geometry

    private func page(_ index: Int) -> PDFPage? { pdfView?.document?.page(at: index) }

    /// A page rectangle in this view's coordinates.
    private func viewRect(_ rect: CGRect, page index: Int) -> NSRect? {
        guard let pdfView, let page = page(index) else { return nil }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    private func viewPoint(_ point: CGPoint, page index: Int) -> NSPoint? {
        guard let pdfView, let page = page(index) else { return nil }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    private var scale: CGFloat { pdfView?.scaleFactor ?? 1 }

    /// The page under a point of this view, and the point on it.
    private func pageLocation(_ point: NSPoint) -> (index: Int, point: CGPoint)? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let inPDF = convert(point, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: false) else { return nil }
        return (document.index(for: page), pdfView.convert(inPDF, to: page))
    }

    /// The object (and handle) under a point of this view.
    private func target(at point: NSPoint) -> (item: AdjustItem, handle: Int?)? {
        // Handles of the outlined object come first: they can stick out.
        if let hovered, !hovered.item.link.handles.isEmpty {
            for index in hovered.item.link.handles.indices {
                if let handle = viewPoint(hovered.item.handle(index), page: hovered.item.page),
                   hypot(handle.x - point.x, handle.y - point.y) <= 6 {
                    return (hovered.item, index)
                }
            }
        }
        guard let location = pageLocation(point), let candidates = items[location.index] else { return nil }
        let tolerance = 3 / scale
        let p = location.point
        let hits = candidates.filter { item in
            guard item.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
            // A slur's box covers the notes under it: only near the curve.
            if item.link.isCurve, item.link.controlPoints.count == 4 {
                return curve(item).contains { hypot($0.x - p.x, $0.y - p.y) <= tolerance * 1.5 }
            }
            return true
        }
        guard let best = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return nil }
        return (best, nil)
    }

    /// Points along a slur or tie, in page coordinates.
    private func curve(_ item: AdjustItem, moving handle: Int? = nil, by delta: CGPoint = .zero) -> [CGPoint] {
        let points = (0..<4).map { index -> CGPoint in
            let point = item.handle(index)
            return handle == nil || handle == index ? CGPoint(x: point.x + delta.x, y: point.y + delta.y) : point
        }
        return (0...32).map { step in
            let t = CGFloat(step) / 32, u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x,
                           y: a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y)
        }
    }

    // MARK: Hover

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) && target(at: local) != nil ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// Recomputes the outlined object for the pointer's current place
    /// (after scrolling, zooming, a new PDF, ⌥).
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) { hover(at: point) } else { setHovered(nil) }
        needsDisplay = true
    }

    func hover(at point: NSPoint) {
        guard drag == nil else { return }
        guard isActive else { return setHovered(nil) }
        let found = target(at: point)
        setHovered(found)
        if found != nil { NSCursor.openHand.set() }
    }

    private func setHovered(_ new: (item: AdjustItem, handle: Int?)?) {
        let changed = new?.item.bounds != hovered?.item.bounds || new?.item.page != hovered?.item.page
            || new?.handle != hovered?.handle
        hovered = new
        guard changed else { return }
        removeAllToolTips()
        if let new, let rect = viewRect(new.item.bounds, page: new.item.page) {
            addToolTip(rect.insetBy(dx: -2, dy: -2), owner: self, userData: nil)
        }
        needsDisplay = true
    }

    /// Whether the pointer is over an object it would drag.
    var isOverObject: Bool { isActive && hovered != nil }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let hovered else { return "" }
        return describe?(hovered.item.link) ?? hovered.item.link.summary
    }

    // MARK: Dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard isActive, let found = target(at: start), let window,
              let startPage = pageLocation(start)?.point else { return super.mouseDown(with: event) }
        setHovered(found)
        var current = Drag(item: found.item, handle: found.handle)
        current.image = found.handle == nil && found.item.link.grob != "Beam" ? snapshot(found.item) : nil
        drag = current
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        let property = AdjustChoices.property(for: found.item.link)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if let location = pageLocation(point), location.index == found.item.page {
                var delta = CGPoint(x: location.point.x - startPage.x, y: location.point.y - startPage.y)
                if found.item.link.grob == "Beam" || (found.handle == nil && property?.isVertical == true) {
                    delta.x = 0
                } else if found.handle == nil && property?.isHorizontal == true {
                    delta.y = 0
                } else if next.modifierFlags.contains(.shift) {
                    if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
                }
                current.delta = delta
                drag = current
                needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }
        drag = nil
        let tweak = self.tweak(for: current, property: property)
        guard let tweak else {
            // Barely moved: a click, which shows the object in the source.
            if hypot(current.delta.x, current.delta.y) * scale < 3 { onReveal?(found.item.link) }
            needsDisplay = true
            return
        }
        pending = current
        needsDisplay = true
        onAdjust?(found.item, tweak) { [weak self] applied in
            guard let self, !applied else { return }
            self.pending = nil
            self.needsDisplay = true
        }
    }

    private func tweak(for drag: Drag, property: AdjustProperty?) -> Tweak? {
        let link = drag.item.link
        let delta = GrobLink.Point(Double(drag.delta.x), Double(drag.delta.y))
        if link.grob == "Beam" {
            return link.beamOffset(left: drag.handle == 1 ? 0 : delta.y, right: drag.handle == 0 ? 0 : delta.y)
        }
        if let handle = drag.handle { return link.shape(movingPoint: handle, by: delta) }
        guard let property else { return nil }
        return link.tweak(property, movedBy: delta)
    }

    /// The object's part of the page, to show under the pointer.
    private func snapshot(_ item: AdjustItem) -> NSImage? {
        guard let page = page(item.page), let rect = viewRect(item.bounds, page: item.page) else { return nil }
        let bounds = item.bounds
        return NSImage(size: rect.size, flipped: false) { target in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: target.width / bounds.width, y: target.height / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            return true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let shown = drag ?? pending {
            drawMoved(shown)
        } else if isActive, let hovered {
            drawOutline(hovered.item, handle: hovered.handle)
        }
    }

    private func drawOutline(_ item: AdjustItem, handle: Int?) {
        // Slurs, ties and beams show their handles instead of a box.
        guard item.link.handles.isEmpty else { return drawHandles(item, moved: nil, by: .zero, active: handle) }
        guard let rect = viewRect(item.bounds, page: item.page) else { return }
        accent.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()
    }

    /// The handles, with handle `moved` moved by `delta`.
    private func drawHandles(_ item: AdjustItem, moved: Int?, by delta: CGPoint, active: Int?) {
        let link = item.link
        guard !link.handles.isEmpty else { return }
        let points = link.handles.indices.compactMap { index -> NSPoint? in
            var point = item.handle(index)
            if index == moved {
                point.x += delta.x
                point.y += delta.y
            }
            return viewPoint(point, page: item.page)
        }
        if link.isCurve, points.count == 4 {
            // The control polygon, faintly.
            let polygon = NSBezierPath()
            polygon.move(to: points[0])
            points.dropFirst().forEach { polygon.line(to: $0) }
            accent.withAlphaComponent(0.35).setStroke()
            polygon.lineWidth = 0.5
            polygon.stroke()
        }
        for (index, point) in points.enumerated() {
            let radius: CGFloat = index == active ? 4 : 3
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            NSColor.white.setFill()
            dot.fill()
            accent.setStroke()
            dot.lineWidth = 1.25
            dot.stroke()
        }
    }

    private func drawMoved(_ shown: Drag) {
        let item = shown.item
        guard let rect = viewRect(item.bounds, page: item.page) else { return }
        let offset = CGPoint(x: shown.delta.x * scale, y: shown.delta.y * scale)
        let link = item.link
        if link.isCurve, shown.handle != nil || shown.image == nil, link.controlPoints.count == 4 {
            // The new curve.
            let points = curve(item, moving: shown.handle, by: shown.delta).compactMap { viewPoint($0, page: item.page) }
            let path = NSBezierPath()
            if let first = points.first { path.move(to: first) }
            points.dropFirst().forEach { path.line(to: $0) }
            accent.setStroke()
            path.lineWidth = max(1, 0.12 * link.pointsPerStaffSpace * scale)
            path.stroke()
            drawHandles(item, moved: shown.handle, by: shown.delta, active: shown.handle)
            return
        }
        if link.grob == "Beam", link.handles.count == 2 {
            // The beam between its moved ends.
            let left = item.handle(0), right = item.handle(1)
            let dl = shown.handle == 1 ? 0 : shown.delta.y, dr = shown.handle == 0 ? 0 : shown.delta.y
            if let a = viewPoint(CGPoint(x: left.x, y: left.y + dl), page: item.page),
               let b = viewPoint(CGPoint(x: right.x, y: right.y + dr), page: item.page) {
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                accent.withAlphaComponent(0.8).setStroke()
                path.lineWidth = max(1.5, 0.48 * link.pointsPerStaffSpace * scale)
                path.stroke()
                for point in [a, b] {
                    let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                    NSColor.white.setFill()
                    dot.fill()
                    accent.setStroke()
                    dot.stroke()
                }
            }
            return
        }
        // Fade the object where it was; show it where it goes.
        NSColor.white.withAlphaComponent(0.6).setFill()
        rect.fill()
        let moved = rect.offsetBy(dx: offset.x, dy: offset.y)
        shown.image?.draw(in: moved, from: .zero, operation: .multiply, fraction: 1)
        accent.setStroke()
        let outline = NSBezierPath(roundedRect: moved.insetBy(dx: -2, dy: -2), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard isActive, let found = target(at: point) else { return nil }
        let link = found.item.link
        let menu = NSMenu(title: link.displayName)
        let properties = link.properties
        if !properties.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Dragging a \(link.displayName.lowercased()) changes"))
            let current = AdjustChoices.property(for: link)
            for property in properties {
                let item = NSMenuItem(title: property.title, action: #selector(chooseProperty(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [link.grob, property.rawValue]
                item.state = property == current ? .on : .off
                item.toolTip = property.rawValue
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if !link.handles.isEmpty {
            let hint = NSMenuItem(title: link.isCurve ? "Drag the handles to reshape" : "Drag an end to tilt",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }
        let reveal = NSMenuItem(title: "Show in Source", action: #selector(revealFromMenu(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menuLink = link
        return menu
    }

    private var menuLink: GrobLink?

    @objc private func chooseProperty(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let property = AdjustProperty(rawValue: pair[1]) else { return }
        AdjustChoices.properties[pair[0]] = property
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        if let menuLink { onReveal?(menuLink) }
    }
}
