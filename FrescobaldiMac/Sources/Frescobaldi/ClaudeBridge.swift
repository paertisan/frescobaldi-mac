import AppKit
import FrescobaldiCore
import FrescobaldiMCP

/// Answers frescobaldi-mcp's requests about open documents, so Claude can
/// read and edit what the user has open (see `Bridge` for the protocol).
/// Runs while Settings > Claude allows it.
@MainActor
final class ClaudeBridge {
    static let shared = ClaudeBridge()

    private var server: BridgeServer?
    /// Why the bridge couldn't start, if it couldn't.
    private(set) var startError: String?

    var isRunning: Bool { server != nil }

    /// Starts or stops the bridge to match the setting.
    func update() {
        if Preferences.claudeAccess { start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        let server = BridgeServer { method, params, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClaudeBridge.handle(method, params, reply) }
            }
        }
        do {
            try server.start()
            self.server = server
            startError = nil
        } catch {
            startError = error.localizedDescription
            NSLog("Claude bridge: %@", error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// The helper Claude runs: Contents/Helpers/frescobaldi-mcp in the app,
    /// or next to the app's executable in a development build.
    static var helperURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/frescobaldi-mcp"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("frescobaldi-mcp"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Requests

    private static func handle(_ method: String, _ params: JSONValue, _ reply: @escaping BridgeServer.Reply) {
        do {
            switch method {
            case "listDocuments":
                reply(.success(listDocuments()))
            case "getDocument":
                reply(.success(try controller(for: params).bridgeSnapshot(includeText: params["include_text"]?.bool ?? true)))
            case "editDocument":
                reply(.success(try controller(for: params).bridgeEdit(params)))
            case "transformDocument":
                try controller(for: params).bridgeTransform(params, reply: reply)
            case "engraveDocument":
                try controller(for: params).bridgeEngrave(params, reply: reply)
            case "reveal":
                reply(.success(try controller(for: params).bridgeReveal(params)))
            default:
                throw BridgeError("Frescobaldi doesn't know the request \(method). Update the app or the helper.")
            }
        } catch {
            reply(.failure(error))
        }
    }

    private static var documents: [LilyPondDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? LilyPondDocument }
    }

    /// The document in the frontmost document window.
    private static var frontmost: LilyPondDocument? {
        NSApp.orderedWindows.lazy.compactMap { ($0.windowController as? DocumentWindowController)?.lilyDocument }.first
            ?? documents.first
    }

    private static func listDocuments() -> JSONValue {
        let front = frontmost
        let items = documents.compactMap { document -> JSONValue? in
            guard let controller = document.windowController else { return nil }
            var summary = controller.bridgeSummary().object ?? [:]
            summary["frontmost"] = .bool(document === front)
            return .object(summary)
        }
        return ["documents": .array(items)]
    }

    /// The document a request names (id, path or file name), or the frontmost one.
    private static func controller(for params: JSONValue) throws -> DocumentWindowController {
        let documents = self.documents
        guard !documents.isEmpty else { throw BridgeError("No documents are open in Frescobaldi.") }
        let key = params["document"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let document: LilyPondDocument?
        if key.isEmpty {
            document = frontmost
        } else {
            let path = URL(fileURLWithPath: (key as NSString).expandingTildeInPath).standardizedFileURL
                .resolvingSymlinksInPath().path
            document = documents.first { $0.bridgeID == key }
                ?? documents.first { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath().path == path }
                ?? unique(documents.filter { $0.fileURL?.lastPathComponent == key || $0.displayName == key })
        }
        guard let document, let controller = document.windowController else {
            let names = documents.map { "\($0.bridgeID) (\($0.displayName ?? "Untitled"))" }.joined(separator: ", ")
            throw BridgeError("No single open document matches \"\(key)\". Open: \(names).")
        }
        return controller
    }

    private static func unique(_ documents: [LilyPondDocument]) -> LilyPondDocument? {
        documents.count == 1 ? documents[0] : nil
    }
}

private extension LilyPondDocument {
    var windowController: DocumentWindowController? {
        windowControllers.lazy.compactMap { $0 as? DocumentWindowController }.first
    }
}

// MARK: - Per-document requests

extension DocumentWindowController {
    func bridgeSummary() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(lilyDocument.bridgeID),
            "name": .string(lilyDocument.displayName ?? "Untitled"),
            "path": JSONValue(lilyDocument.fileURL?.path),
            "edited": .bool(lilyDocument.isDocumentEdited),
            "pdf": JSONValue(engraveModel.pdfs.first?.path),
        ]
        if let last = lastEngrave(withIssues: false) { object["last_engrave"] = last }
        return .object(object)
    }

    func bridgeSnapshot(includeText: Bool) -> JSONValue {
        var object = bridgeSummary().object ?? [:]
        let text = editor.textView.nsString
        let selection = editor.textView.selectedRange()
        object["lines"] = .int(editor.lines.lineCount)
        object["selection"] = [
            "start": position(selection.location, in: text),
            "end": position(NSMaxRange(selection), in: text),
            "text": .string(text.substring(with: selection)),
        ]
        if let last = lastEngrave(withIssues: true) { object["last_engrave"] = last }
        if includeText { object["text"] = .string(text as String) }
        return .object(object)
    }

    /// 1-based line and column (in characters, as LilyPond counts).
    private func position(_ location: Int, in text: NSString) -> JSONValue {
        let position = TextEditLink.position(of: location, in: text)
        return ["line": .int(position.line), "column": .int(position.column + 1)]
    }

    private func lastEngrave(withIssues: Bool) -> JSONValue? {
        var object: [String: JSONValue]
        switch engraveModel.status {
        case .idle:
            return nil
        case .running:
            object = ["status": "running"]
        case let .finished(succeeded, errors, warnings, _):
            object = ["status": .string(succeeded && errors == 0 ? "succeeded" : "failed"),
                      "errors": .int(errors), "warnings": .int(warnings)]
            if withIssues { object["issues"] = .array(engraveModel.messages.map(EngraveReport.issue)) }
        case .cancelled:
            object = ["status": "cancelled"]
        case let .failed(message):
            object = ["status": "failed", "message": .string(message)]
        }
        return .object(object)
    }

    /// Applies Claude's changes as one undoable edit and selects the result.
    func bridgeEdit(_ params: JSONValue) throws -> JSONValue {
        let original = lilyDocument.text
        let newText: String
        if let text = params["text"]?.string {
            newText = text
        } else if let edits = params["edits"]?.array, !edits.isEmpty {
            let substitutions = try edits.map { edit -> TextSubstitution in
                guard let old = edit["old_text"]?.string, let new = edit["new_text"]?.string else {
                    throw BridgeError("Each edit needs old_text and new_text.")
                }
                return TextSubstitution(old: old, new: new)
            }
            newText = try TextSubstitution.apply(substitutions, to: original)
        } else {
            throw BridgeError("Give `edits` (old_text/new_text pairs) or `text`.")
        }
        guard let change = TextReplacement.between(original, newText) else { return ["changed": false] }
        let changed = NSRange(location: change.range.location, length: (change.replacement as NSString).length)
        editor.textView.replace(change.range, with: change.replacement, selection: changed, actionName: "Claude Edit")
        editor.textView.scrollRangeToVisible(changed)
        if changed.length > 0 { editor.textView.showFindIndicator(for: changed) }
        let text = editor.textView.nsString
        return [
            "changed": true,
            "first_line": .int(TextLines.lineNumber(at: changed.location, in: text)),
            "last_line": .int(TextLines.lineNumber(at: NSMaxRange(changed), in: text)),
            "lines": .int(editor.lines.lineCount),
        ]
    }

    func bridgeTransform(_ params: JSONValue, reply: @escaping BridgeServer.Reply) throws {
        let edit = try LyEditArguments.edit(from: params)
        let wholeDocument = params["whole_document"]?.bool ?? false
        let scope = wholeDocument || editor.textView.selectedRange().length == 0 ? "document" : "selection"
        runLyEdit(edit, name: LyEditArguments.undoName(edit), wholeDocument: wholeDocument) { result in
            reply(result.map { changed in ["changed": .bool(changed), "scope": .string(scope)] })
        }
    }

    func bridgeEngrave(_ params: JSONValue, reply: @escaping BridgeServer.Reply) throws {
        let mode: EngraveJob.Mode = params["mode"]?.string == "publish" ? .publish : .preview
        let id = lilyDocument.bridgeID
        engrave(mode: mode) { result in
            reply(result.map { result in
                var object = EngraveReport.json(result).object ?? [:]
                object["document"] = .string(id)
                // A file of a larger project engraves the project's target.
                if let target = self.engraveModel.targetName { object["engraved"] = .string(target) }
                return .object(object)
            })
        }
    }

    func bridgeReveal(_ params: JSONValue) throws -> JSONValue {
        guard let line = params["line"]?.int else { throw BridgeError("Give `line` (1-based).") }
        let text = editor.textView.nsString
        func location(line: Int, column: Int) throws -> Int {
            let link = TextEditLink(path: "", line: line, startColumn: max(0, column - 1), endColumn: max(0, column - 1))
            guard let range = link.range(in: text) else {
                throw BridgeError("There's no line \(line); the document has \(editor.lines.lineCount) lines.")
            }
            return range.location
        }
        let start = try location(line: line, column: params["column"]?.int ?? 1)
        var range = NSRange(location: start, length: 0)
        if let endLine = params["end_line"]?.int {
            // Without end_column, select to the end of end_line.
            let end = try location(line: endLine, column: params["end_column"]?.int ?? Int.max / 2)
            range = NSRange(location: min(start, end), length: abs(end - start))
        }
        editor.textView.reveal(range)
        if params["activate"]?.bool == true {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return ["selection": [
            "start": position(range.location, in: text),
            "end": position(NSMaxRange(range), in: text),
            "text": .string(text.substring(with: range)),
        ]]
    }
}
