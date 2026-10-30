import Foundation
import FrescobaldiCore

/// The tools `frescobaldi-mcp` offers.
public enum FrescobaldiTools {
    public static let serverName = "frescobaldi"
    public static let version = "0.1.0"

    public static let instructions = """
        Tools for LilyPond music engraving, backed by Frescobaldi for macOS.
        - Scores open in Frescobaldi: use list_documents, get_document, edit_document, \
        engrave_document, reveal, and transform/outline/render_page with `document`. \
        Edits show up in the user's editor as one undoable change. Omit `document` \
        to use the frontmost one. Prefer these over editing the file on disk while \
        it is open.
        - Files on disk, or source text: engrave, transform, outline, render_page.
        - Workflow: engrave, read the issues (1-based line and column in the source; \
        none for a message such as an unknown paper size), fix them, engrave again, \
        then render_page to look at the result.
        - Pitches for transpose are Dutch names with octave marks (c, cis, bes, d'), \
        whatever language the document uses.
        """

    public static func all(environment: FrescobaldiEnvironment = .detect(),
                           bridge: BridgeClient = BridgeClient()) -> [MCPTool] {
        let context = Context(environment: environment, bridge: bridge)
        return [
            // Files on disk
            MCPTool(name: "engrave", title: "Engrave LilyPond",
                    description: """
                        Run LilyPond on a .ly file (or on LilyPond source text) and report the errors and \
                        warnings with file, line, column and the source line, plus the PDF and MIDI files \
                        written. An include file engraves the score that includes it (its master, or a \
                        .ly in the project that includes it). A project's frescobaldi.json adds include \
                        paths and an output folder; otherwise output goes next to the file (for text: a \
                        temporary folder). For a score that is open in Frescobaldi, use engrave_document \
                        instead.
                        """,
                    inputSchema: schema([
                        "path": string("Path of the .ly file to engrave, or of a file it includes."),
                        "text": string("LilyPond source to engrave instead of a file."),
                        "mode": string("`preview` (default) adds point-and-click links; `publish` leaves them out.",
                                       oneOf: ["preview", "publish"]),
                    ]),
                    annotations: MCPToolAnnotations(readOnly: false, idempotent: true),
                    run: { try await context.engrave($0) }),
            MCPTool(name: "render_page", title: "Render Score Page",
                    description: """
                        Render a page of an engraved score as a PNG image, to check the notation visually. \
                        Give a .pdf, a .ly file (its up-to-date PDF is used), or `document` for the PDF \
                        shown in Frescobaldi. By default long blank stretches are shortened; set trim to \
                        false for the exact page layout.
                        """,
                    inputSchema: schema([
                        "path": string("A .pdf file, or a .ly file whose PDF to show."),
                        "document": documentProperty,
                        "page": integer("Page number, starting at 1 (default 1).", minimum: 1),
                        "width": integer("Image width in pixels, 200-2000 (default 1000).", minimum: 200, maximum: 2000),
                        "trim": boolean("Shorten long blank stretches (default true)."),
                    ]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: { try await context.renderPage($0) }),
            MCPTool(name: "transform", title: "Transform LilyPond Music",
                    description: """
                        Run one of Frescobaldi's music tools (python-ly): transpose, translate pitch names \
                        to another language, relative_to_absolute, absolute_to_relative, \
                        simplify_accidentals, reindent or reformat. The whole document is parsed, so \
                        \\language and enclosing \\relative blocks are respected. Targets: `document` \
                        (an open score; changes its selection, or everything if there's no selection or \
                        whole_document is true; undoable), `path` (returns the new text; set write to \
                        save it), or `text` (returns the new text).
                        """,
                    inputSchema: schema([
                        "operation": string("What to do.", oneOf: LyEditArguments.operations),
                        "from": string("transpose: pitch to transpose from, Dutch names with octave marks, e.g. c, bes, fis'."),
                        "to": string("transpose: pitch to transpose to, e.g. d."),
                        "language": string("translate: target pitch-name language.", oneOf: LyEdit.languages),
                        "document": documentProperty,
                        "whole_document": boolean("document: ignore the selection and change everything."),
                        "path": string("A .ly file to transform."),
                        "write": boolean("path: save the result to the file (default false)."),
                        "text": string("LilyPond source to transform."),
                    ], required: ["operation"]),
                    annotations: MCPToolAnnotations(readOnly: false, destructive: true),
                    run: { try await context.transform($0) }),
            MCPTool(name: "outline", title: "Outline LilyPond Source",
                    description: """
                        List the structure of LilyPond source: \\version, \\include, variable assignments, \
                        \\score/\\book/\\header/\\layout/\\midi blocks and %% markers, with line numbers \
                        and nesting level. For a path, text, or an open `document`.
                        """,
                    inputSchema: schema([
                        "path": string("A .ly or .ily file."),
                        "text": string("LilyPond source."),
                        "document": documentProperty,
                    ]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: { try await context.outline($0) }),
            MCPTool(name: "lilypond_info", title: "LilyPond Installation",
                    description: "Which LilyPond Frescobaldi uses: path, version and CPU architecture.",
                    inputSchema: schema([:]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: { try await context.lilypondInfo($0) }),
            MCPTool(name: "templates", title: "Score Templates",
                    description: """
                        Without `name`, list Frescobaldi's score templates. With `name`, return that template \
                        as LilyPond source with \\version set to the installed LilyPond, and the line and \
                        column where music should go.
                        """,
                    inputSchema: schema(["name": string("Template name from the list.")]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: { try await context.templates($0) }),

            // The running app
            MCPTool(name: "list_documents", title: "List Open Scores",
                    description: """
                        List the documents open in Frescobaldi: id, name, path, unsaved changes, which one \
                        is frontmost, and the result of the last engrave.
                        """,
                    inputSchema: schema([:]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: context.bridgeCall("listDocuments")),
            MCPTool(name: "get_document", title: "Read Open Score",
                    description: """
                        Read a document open in Frescobaldi: its text, the user's selection and cursor \
                        (1-based line and column), unsaved state, its PDF, and the issues from the last \
                        engrave.
                        """,
                    inputSchema: schema([
                        "document": documentProperty,
                        "include_text": boolean("Include the full text (default true)."),
                    ]),
                    annotations: MCPToolAnnotations(readOnly: true),
                    run: context.bridgeCall("getDocument")),
            MCPTool(name: "edit_document", title: "Edit Open Score",
                    description: """
                        Change a document open in Frescobaldi, as one change the user can undo \
                        (Edit > Undo Claude Edit). Give `edits`: each old_text must occur exactly once \
                        (include enough surrounding text) and is replaced by new_text, in order; if any \
                        fails nothing changes. Or give `text` to replace everything. The document isn't \
                        saved; engrave_document saves it first.
                        """,
                    inputSchema: schema([
                        "document": documentProperty,
                        "edits": .object([
                            "type": "array",
                            "description": "Replacements, applied in order.",
                            "items": schema([
                                "old_text": string("Exact text to replace; must occur once."),
                                "new_text": string("Replacement text."),
                            ], required: ["old_text", "new_text"]),
                        ]),
                        "text": string("New text for the whole document."),
                    ]),
                    annotations: MCPToolAnnotations(readOnly: false, destructive: true),
                    run: context.bridgeCall("editDocument")),
            MCPTool(name: "engrave_document", title: "Engrave Open Score",
                    description: """
                        Engrave a document open in Frescobaldi, as if the user pressed ⌘R: a saved document \
                        with changes is saved first, an untitled one is engraved from a temporary copy. \
                        Waits for LilyPond and returns errors and warnings (line and column in the \
                        source) and the PDF. The preview in the app updates.
                        """,
                    inputSchema: schema([
                        "document": documentProperty,
                        "mode": string("`preview` (default) or `publish` (no point-and-click links).",
                                       oneOf: ["preview", "publish"]),
                    ]),
                    annotations: MCPToolAnnotations(readOnly: false),
                    run: context.bridgeCall("engraveDocument", timeout: 900)),
            MCPTool(name: "reveal", title: "Show Location in Score",
                    description: """
                        Select a place in a document open in Frescobaldi and scroll to it; the matching notes \
                        are highlighted in the PDF preview. Lines and columns are 1-based; give end_line and \
                        end_column to select a range. Set activate to bring Frescobaldi to the front.
                        """,
                    inputSchema: schema([
                        "document": documentProperty,
                        "line": integer("Line, starting at 1.", minimum: 1),
                        "column": integer("Column, starting at 1 (default 1).", minimum: 1),
                        "end_line": integer("End line of a range.", minimum: 1),
                        "end_column": integer("End column of a range (exclusive).", minimum: 1),
                        "activate": boolean("Bring Frescobaldi to the front (default false)."),
                    ], required: ["line"]),
                    annotations: MCPToolAnnotations(readOnly: false, idempotent: true),
                    run: context.bridgeCall("reveal")),
        ]
    }

    static let documentProperty = string("""
        A document open in Frescobaldi: its id from list_documents, its path, or its file name. \
        Default: the frontmost document.
        """)

    // MARK: Schema helpers

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { object["required"] = JSONValue(required) }
        return .object(object)
    }

    static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { object["enum"] = JSONValue(values) }
        return .object(object)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { object["minimum"] = .int(minimum) }
        if let maximum { object["maximum"] = .int(maximum) }
        return .object(object)
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }
}

// MARK: - Implementations

private struct Context: Sendable {
    let environment: FrescobaldiEnvironment
    let bridge: BridgeClient

    /// A path argument: `~` expanded, must exist.
    func file(_ arguments: JSONValue, key: String = "path") throws -> URL? {
        guard let path = arguments[key]?.string, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError("No such file: \(url.path)") }
        return url
    }

    func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Source text from `path`, `text` or an open `document`.
    func sourceText(_ arguments: JSONValue) async throws -> String {
        if let url = try file(arguments) { return try readText(url) }
        if let text = arguments["text"]?.string { return text }
        let document = try await callBridge("getDocument", ["document": arguments["document"] ?? .null])
        guard let text = document["text"]?.string else { throw MCPToolError("The document has no text.") }
        return text
    }

    func callBridge(_ method: String, _ params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        let bridge = self.bridge
        return try await blocking { try bridge.call(method, params, timeout: timeout) }
    }

    func bridgeCall(_ method: String, timeout: TimeInterval = 30) -> @Sendable (JSONValue) async throws -> MCPToolResult {
        { arguments in .json(try await callBridge(method, arguments, timeout: timeout)) }
    }

    // MARK: engrave

    func engrave(_ arguments: JSONValue) async throws -> MCPToolResult {
        let source: URL
        if let url = try file(arguments) {
            source = url
        } else if let text = arguments["text"]?.string {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("frescobaldi-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("snippet.ly")
            try Data(text.utf8).write(to: source)
        } else {
            throw MCPToolError("Give `path` (a .ly file) or `text` (LilyPond source).")
        }
        guard let lilypond = environment.lilypond() else {
            throw MCPToolError("LilyPond wasn't found. Install it (brew install lilypond) or set its location in Frescobaldi's Settings.")
        }
        let mode: EngraveJob.Mode = arguments["mode"]?.string == "publish" ? .publish : .preview
        var target = source
        var options: (outputBase: URL?, arguments: [String]) = (nil, [])
        if arguments["path"] != nil {
            // As ⌘R in the app: the file's target, with the project's settings.
            let project = try await blocking { LilyPondProject.open(source) }
            guard let found = project.target else {
                throw MCPToolError("\(source.lastPathComponent) makes no output by itself (no \\score, music or \\markup at top level), and no .ly file in \(project.root.path) includes it.")
            }
            target = found
            options = project.engraveOptions(for: found)
        }
        let job = EngraveJob(lilypond: lilypond, source: target, outputBase: options.outputBase, mode: mode,
                             extraArguments: options.arguments)
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: MCPToolError("Couldn't start LilyPond: \(error.localizedDescription)"))
            }
        }
        var report = EngraveReport.json(result).object ?? [:]
        report["source"] = .string(target.path)
        return .json(.object(report))
    }

    // MARK: render_page

    func renderPage(_ arguments: JSONValue) async throws -> MCPToolResult {
        let pdf: URL
        if let url = try file(arguments) {
            if url.pathExtension.lowercased() == "pdf" {
                pdf = url
            } else if let found = EngraveJob.existingOutputs(
                for: url, outputDirectory: ProjectSettings.root(containing: url.deletingLastPathComponent()).flatMap { root in
                    (try? ProjectSettings.load(root: root))?.outputDirectory(root: root)
                }).pdfs.first {
                pdf = found
            } else {
                throw MCPToolError("\(url.lastPathComponent) has no up-to-date PDF. Engrave it first.")
            }
        } else {
            let document = try await callBridge("getDocument", ["document": arguments["document"] ?? .null,
                                                                "include_text": false])
            guard let path = document["pdf"]?.string else {
                throw MCPToolError("\(document["name"]?.string ?? "The document") hasn't been engraved yet. Use engrave_document first.")
            }
            pdf = URL(fileURLWithPath: path)
        }
        let number = arguments["page"]?.int ?? 1
        let width = min(2000, max(200, arguments["width"]?.int ?? 1000))
        let trim = arguments["trim"]?.bool ?? true
        let page = try await blocking { try PageRenderer.render(pdf: pdf, page: number, width: width, trim: trim) }
        var caption = "Page \(number) of \(page.pageCount) of \(pdf.path), \(page.width)×\(page.height) px."
        if page.trimmed { caption += " Long blank stretches were shortened; use trim: false for the real layout." }
        return MCPToolResult(content: [.image(page.png, mimeType: "image/png"), .text(caption)])
    }

    // MARK: transform

    func transform(_ arguments: JSONValue) async throws -> MCPToolResult {
        let edit = try LyEditArguments.edit(from: arguments)
        if arguments["path"]?.string == nil && arguments["text"]?.string == nil {
            return .json(try await callBridge("transformDocument", arguments, timeout: 60))
        }
        let tool = try environment.pythonLyTool()
        let url = try file(arguments)
        let original = try url.map(readText) ?? arguments["text"]?.string ?? ""
        let changed = try await blocking { try tool.apply(edit, to: original) }
        var result: [String: JSONValue] = ["changed": .bool(changed != original)]
        if let url, arguments["write"]?.bool == true, changed != original {
            try Data(changed.utf8).write(to: url, options: .atomic)
            result["written"] = .string(url.path)
        }
        result["text"] = .string(changed)
        return .json(.object(result))
    }

    // MARK: outline, info, templates

    func outline(_ arguments: JSONValue) async throws -> MCPToolResult {
        let text = try await sourceText(arguments) as NSString
        let items = DocumentOutline.items(in: text).map { item -> JSONValue in
            ["kind": .string(item.kind.rawValue), "title": .string(item.title), "line": .int(item.line),
             "level": .int(item.level)]
        }
        return .json(["items": .array(items)])
    }

    func lilypondInfo(_ arguments: JSONValue) async throws -> MCPToolResult {
        guard let lilypond = environment.lilypond() else {
            throw MCPToolError("LilyPond wasn't found. Install it (brew install lilypond) or set its location in Frescobaldi's Settings.")
        }
        let (version, architectures) = await blockingValue {
            (LilyPondLocator.version(of: lilypond), LilyPondLocator.architectures(of: lilypond))
        }
        return .json([
            "path": .string(lilypond.path),
            "version": JSONValue(version?.description),
            "architectures": JSONValue(architectures.map(\.rawValue)),
            "setting": .string(environment.lilypondSetting.isEmpty ? "automatic" : environment.lilypondSetting),
        ])
    }

    func templates(_ arguments: JSONValue) async throws -> MCPToolResult {
        guard let directory = environment.templatesDirectory else {
            throw MCPToolError("The templates weren't found next to frescobaldi-mcp.")
        }
        let templates = LilyPondTemplate.templates(in: directory)
        guard let name = arguments["name"]?.string, !name.isEmpty else {
            return .json(["templates": JSONValue(templates.map(\.name))])
        }
        guard let template = templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MCPToolError("No template named \(name). Templates: \(templates.map(\.name).joined(separator: ", ")).")
        }
        let version = await blockingValue { environment.lilypond().flatMap(LilyPondLocator.version(of:)) }
        let rendered = try template.render(version: version)
        let position = TextEditLink.position(of: rendered.cursor, in: rendered.text as NSString)
        return .json([
            "name": .string(template.name),
            "text": .string(rendered.text),
            "cursor": ["line": .int(position.line), "column": .int(position.column + 1)],
        ])
    }
}

/// Runs blocking work (processes, sockets, rendering) off the cooperative pool.
private func blocking<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

private func blockingValue<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
