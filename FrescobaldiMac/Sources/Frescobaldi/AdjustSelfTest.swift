#if DEBUG
import AppKit
import FrescobaldiCore
import QuartzCore

/// Development builds only (CONFIG=debug scripts/build-app.sh): drives the
/// preview's Adjust mode in the running app without screen control.
///
///   FMAC_SELFTEST=/path/score.ly FMAC_SELFTEST_OUT=/dir Frescobaldi.app/Contents/MacOS/Frescobaldi
///
/// Opens the score, engraves it, turns Adjust on, hovers and drags a few
/// objects with posted mouse events (through the real hit testing, drag
/// loop, edit and engrave), saves window snapshots and report.txt in the
/// output folder, then quits.
@MainActor enum AdjustSelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["FMAC_SELFTEST"] != nil }

    private static var report: [String] = []
    private static var out = URL(fileURLWithPath: NSTemporaryDirectory())

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMAC_SELFTEST"] else { return }
        out = URL(fileURLWithPath: env["FMAC_SELFTEST_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, error in
            guard let controller = (document as? LilyPondDocument)?.windowControllers.first as? DocumentWindowController
            else { return finish("couldn't open: \(String(describing: error))") }
            controller.window?.setContentSize(NSSize(width: 1400, height: 900))
            controller.engrave(mode: .preview) { result in
                log("engrave: \((try? result.get().succeeded) ?? false)")
                after(1) { steps(controller) }
            }
        }
    }

    private static func log(_ line: String) {
        report.append(line)
        NSLog("AdjustSelfTest: %@", line)
    }

    private static func finish(_ line: String) {
        log(line)
        try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    private static func snapshot(_ controller: DocumentWindowController, _ name: String) {
        guard let window = controller.window, let view = window.contentView?.superview ?? window.contentView else { return }
        window.displayIfNeeded()
        CATransaction.flush()
        // The window server's picture (PDFKit draws pages in layers that
        // cacheDisplay misses), else the views' own drawing.
        var data: Data?
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            // The preview only, at full resolution.
            let preview = controller.preview.view
            let frame = preview.convert(preview.bounds, to: nil)
            let factor = CGFloat(image.width) / window.frame.width
            let crop = CGRect(x: frame.minX * factor, y: (window.frame.height - frame.maxY) * factor,
                              width: frame.width * factor, height: frame.height * factor)
            let cropped = name.hasPrefix("0-") ? image : (image.cropping(to: crop) ?? image)
            data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        }
        if data == nil, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        try? data?.write(to: out.appendingPathComponent(name + ".png"))
    }

    private static func event(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Queued for the drag loop's nextEvent.
    private static func post(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) {
        if let event = event(type, point, in: window) { NSApp.postEvent(event, atStart: false) }
    }

    /// A drag of `item` (or one of its handles) by `delta` window points.
    private static func drag(_ controller: DocumentWindowController, _ item: AdjustItem, handle: Int? = nil,
                             by delta: NSPoint, name: String, then next: @escaping @MainActor () -> Void) {
        let overlay = controller.preview.adjustOverlay
        if let page = controller.preview.pdfView.document?.page(at: item.page) {
            controller.preview.pdfView.go(to: item.bounds.insetBy(dx: -60, dy: -60), on: page)
        }
        overlay.hover(atWindowPoint: overlay.windowPoint(of: item, handle: item.link.handles.isEmpty ? nil : 0) ?? .zero)
        guard let window = controller.window, let start = overlay.windowPoint(of: item, handle: handle) else {
            log("\(name): no point"); return next()
        }
        let before = controller.lilyDocument.text
        overlay.hover(atWindowPoint: start)
        snapshot(controller, name + "-hover")
        // Snapshot mid-drag (the drag loop runs timers in common modes).
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                snapshot(controller, name + "-dragging")
                post(.leftMouseUp, NSPoint(x: start.x + delta.x, y: start.y + delta.y), in: window)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Straight to the overlay: a background app's window holds clicks
        // back until it's active. Its hitTest must claim the point first.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let inSuperview = overlay.superview?.convert(start, from: nil) ?? start
                let claims = overlay.hitTest(inSuperview) === overlay
                log("\(name): overlay claims the click: \(claims)")
                // Queued now, so the drag loop is the one that reads them.
                post(.leftMouseDragged, NSPoint(x: start.x + delta.x / 2, y: start.y + delta.y / 2), in: window)
                post(.leftMouseDragged, NSPoint(x: start.x + delta.x, y: start.y + delta.y), in: window)
                if claims, let down = event(.leftMouseDown, start, in: window) { overlay.mouseDown(with: down) }
            }
        }
        waitForEngrave(controller, since: before) {
            let text = controller.lilyDocument.text
            let change = TextReplacement.between(before, text)
            log("\(name): \(item.link.summary) → \(change.map { "“\($0.replacement)” at \($0.range.location)" } ?? "no change") notice: \(controller.engraveModel.notice ?? "-") status: \(controller.engraveModel.status) sheet: \(controller.window?.attachedSheet.map { String(describing: $0) } ?? "-") edited: \(controller.lilyDocument.isDocumentEdited)")
            snapshot(controller, name + "-after")
            next()
        }
    }

    /// Until the text changed and a new PDF is shown (or 20 s).
    private static func waitForEngrave(_ controller: DocumentWindowController, since text: String, tries: Int = 0,
                                       then body: @escaping @MainActor () -> Void) {
        let pdfDate = controller.preview.pdfDate
        func poll(_ tries: Int) {
            after(0.5) {
                let changed = controller.lilyDocument.text != text
                let reloaded = controller.preview.pdfDate != pdfDate && !controller.engraveModel.isRunning
                if (changed && reloaded) || tries > 40 { after(0.5, body) } else { poll(tries + 1) }
            }
        }
        poll(0)
    }

    /// An object written in an included file: the file opens as a tab and
    /// takes the edit; the score's window stays in front.
    private static func includeStep(_ controller: DocumentWindowController) {
        guard let dynamic = item(controller, { $0.grob == "DynamicText" }) else { return finish("no dynamic") }
        log("include: object in \(URL(fileURLWithPath: dynamic.link.path).lastPathComponent)")
        drag(controller, dynamic, by: NSPoint(x: 30, y: 0), name: "5-include") {
            for document in NSDocumentController.shared.documents.compactMap({ $0 as? LilyPondDocument }) {
                log("include: \(document.displayName) \(document.text.contains("tweak") ? "has the tweak" : "unchanged")")
            }
            log("include: tabs \(controller.window?.tabbedWindows?.count ?? 1), selected tab is the score: \(controller.window?.tabGroup?.selectedWindow === controller.window)")
            let disk = (try? String(contentsOfFile: dynamic.link.path, encoding: .utf8)) ?? ""
            log("include: saved with the tweak: \(disk.contains("tweak"))")
            finish("done")
        }
    }

    /// The right-click menu, the tooltip and ⌥ without the toggle.
    private static func checkMenuAndOption(_ controller: DocumentWindowController) {
        let overlay = controller.preview.adjustOverlay
        guard let window = controller.window,
              let dynamic = item(controller, { $0.grob == "DynamicText" && $0.label == "p" }),
              let point = overlay.windowPoint(of: dynamic, handle: nil) else { return log("menu: no dynamic") }
        overlay.hover(atWindowPoint: point)
        log("tooltip: \(overlay.view(overlay, stringForToolTip: 0, point: .zero, userData: nil))")
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let menu = overlay.menu(for: event) {
            log("menu: " + menu.items.map { ($0.state == .on ? "✓" : "") + ($0.isSeparatorItem ? "—" : $0.title) }.joined(separator: " | "))
        }
        let inSuperview = overlay.superview?.convert(point, from: nil) ?? point
        overlay.isOn = false
        log("off: claims \(overlay.hitTest(inSuperview) === overlay)")
        overlay.optionHeld = true
        log("⌥ held: claims \(overlay.hitTest(inSuperview) === overlay)")
        overlay.optionHeld = false
        overlay.isOn = true
    }

    private static func item(_ controller: DocumentWindowController, _ test: (GrobLink) -> Bool) -> AdjustItem? {
        controller.preview.adjustOverlay.items.values.flatMap { $0 }.first { test($0.link) }
    }

    private static func steps(_ controller: DocumentWindowController) {
        let overlay = controller.preview.adjustOverlay
        log("objects: \(overlay.items.values.reduce(0) { $0 + $1.count })")
        controller.window?.makeKey()
        controller.preview.pdfView.autoScales = false
        controller.preview.pdfView.scaleFactor = 1.6
        if let page = controller.preview.pdfView.document?.page(at: 0) {
            controller.preview.pdfView.go(to: CGRect(x: 0, y: 650, width: 300, height: 200), on: page)
        }
        controller.toggleAdjust(nil)
        log("adjusting: \(overlay.isOn)")
        snapshot(controller, "0-adjust-on")
        if ProcessInfo.processInfo.environment["FMAC_SELFTEST_INCLUDE"] != nil { return includeStep(controller) }
        guard let accent = item(controller, { $0.grob == "Script" && $0.label == "accent" }) else { return finish("no accent") }
        checkMenuAndOption(controller)
        drag(controller, accent, by: NSPoint(x: 40, y: 25), name: "1-accent") {
            AdjustChoices.properties["DynamicText"] = .staffPadding
            guard let dynamic = item(controller, { $0.grob == "DynamicText" && $0.label == "p" }) else { return finish("no p") }
            drag(controller, dynamic, by: NSPoint(x: 0, y: -30), name: "2-dynamic-staff-padding") {
                guard let slur = item(controller, { $0.grob == "Slur" }) else { return finish("no slur") }
                // The curve's ends are on it; its box's centre isn't.
                overlay.hover(atWindowPoint: overlay.windowPoint(of: slur, handle: 0) ?? .zero)
                drag(controller, slur, handle: 2, by: NSPoint(x: 0, y: 30), name: "3-slur-handle") {
                    guard let beam = item(controller, { $0.grob == "Beam" && $0.event == "note-event" }) else { return finish("no beam") }
                    overlay.hover(atWindowPoint: overlay.windowPoint(of: beam, handle: nil) ?? .zero)
                    drag(controller, beam, handle: 0, by: NSPoint(x: 0, y: 20), name: "4-beam-end") {
                        // Undo puts the beam back: one undoable change each.
                        let before = controller.lilyDocument.text
                        controller.lilyDocument.undoManager?.undo()
                        log("undo: \(controller.lilyDocument.undoManager?.redoActionName ?? "") changed \(before != controller.lilyDocument.text)")
                        finish("done")
                    }
                }
            }
        }
    }
}

extension AdjustOverlay {
    /// The window point of an object's centre or handle.
    func windowPoint(of item: AdjustItem, handle: Int?) -> NSPoint? {
        guard let pdfView, let page = pdfView.document?.page(at: item.page) else { return nil }
        let point = handle.map { item.handle($0) } ?? CGPoint(x: item.bounds.midX, y: item.bounds.midY)
        return convert(convert(pdfView.convert(point, from: page), from: pdfView), to: nil)
    }

    func hover(atWindowPoint point: NSPoint) {
        hover(at: convert(point, from: nil))
    }
}
#endif
