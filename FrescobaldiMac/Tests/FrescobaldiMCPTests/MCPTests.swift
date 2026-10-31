import CoreGraphics
import Foundation
import Testing
import FrescobaldiCore
@testable import FrescobaldiMCP

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrescobaldiMCPTests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Socket paths must stay short (104 bytes), so not in a nested temp dir.
private func socketPath() -> String {
    "/tmp/fmac-test-\(UUID().uuidString.prefix(8)).sock"
}

private func response(_ server: MCPServer, _ request: JSONValue) async throws -> JSONValue {
    let line = try #require(await server.handle(request.encodedString()))
    return try JSONValue.parse(line)
}

private func call(_ server: MCPServer, _ tool: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
    let reply = try await response(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                            "params": ["name": .string(tool), "arguments": arguments]])
    return try #require(reply["result"])
}

private func text(_ result: JSONValue) -> String {
    result["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
}

@Suite struct JSONValueTests {
    @Test func roundTrip() throws {
        let value: JSONValue = ["a": 1, "b": 1.5, "c": "x/y", "d": [true, nil], "e": ["f": "🎵"]]
        #expect(try JSONValue.parse(value.encodedString()) == value)
        #expect(value.encodedString() == #"{"a":1,"b":1.5,"c":"x/y","d":[true,null],"e":{"f":"🎵"}}"#)
        #expect(JSONValue.double(2).int == 2 && JSONValue.double(2.5).int == nil)
        #expect(try JSONValue.parse("7") == .int(7))
    }
}

@Suite struct MCPServerTests {
    let server = MCPServer(name: "test", version: "1", instructions: "Hi", tools: [
        MCPTool(name: "echo", title: "Echo", description: "Echoes.", inputSchema: ["type": "object"],
                annotations: MCPToolAnnotations(readOnly: true)) { .json($0) },
        MCPTool(name: "fail", title: "Fail", description: "Fails.", inputSchema: ["type": "object"],
                annotations: MCPToolAnnotations(readOnly: false, destructive: true)) { _ in
            throw MCPToolError("nope")
        },
    ])

    @Test func initialize() async throws {
        let reply = try await response(server, ["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                                "params": ["protocolVersion": "2025-03-26"]])
        #expect(reply["id"] == "a")
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["serverInfo"]?["name"] == "test")
        #expect(reply["result"]?["instructions"] == "Hi")
        let future = try await response(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                                 "params": ["protocolVersion": "2099-01-01"]])
        #expect(future["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions.last!))
    }

    @Test func notificationsAndErrors() async throws {
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await response(server, ["jsonrpc": "2.0", "id": 3, "method": "ping"])["result"] == [:])
        let unknown = try await response(server, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        #expect(unknown["error"]?["code"] == -32601)
        let parse = try JSONValue.parse(try #require(await server.handle("{nope")))
        #expect(parse["error"]?["code"] == -32700 && parse["id"] == .null)
        let noTool = try await response(server, ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                                 "params": ["name": "missing"]])
        #expect(noTool["error"]?["code"] == -32602)
    }

    @Test func tools() async throws {
        let list = try await response(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try #require(list["result"]?["tools"]?.array)
        #expect(tools.map { $0["name"] } == ["echo", "fail"])
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
        #expect(tools[1]["annotations"]?["destructiveHint"] == true)

        let echoed = try await call(server, "echo", ["x": 1])
        #expect(echoed["isError"] == nil)
        #expect(try JSONValue.parse(text(echoed)) == ["x": 1])
        let failed = try await call(server, "fail")
        #expect(failed["isError"] == true && text(failed) == "nope")
    }
}

@Suite(.timeLimit(.minutes(1))) struct BridgeTests {
    @Test func roundTrip() throws {
        let path = socketPath()
        let server = BridgeServer(socketPath: path) { method, params, reply in
            switch method {
            case "echo": reply(.success(params))
            case "later": DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply(.success("done")) }
            default: reply(.failure(BridgeError("unknown \(method)")))
            }
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let client = BridgeClient(socketPath: path)
        #expect(client.isAvailable)
        #expect(try client.call("echo", ["text": "🎵\n"]) == ["text": "🎵\n"])
        #expect(try client.call("later") == "done")
        #expect(throws: BridgeError("unknown other")) { try client.call("other") }

        // A second app instance must not take over the socket.
        #expect(throws: BridgeError.self) { try BridgeServer(socketPath: path) { _, _, _ in }.start() }
    }

    @Test func notRunningAndStaleSocket() throws {
        let path = socketPath()
        #expect(throws: BridgeError(Bridge.notRunningMessage)) { try BridgeClient(socketPath: path).call("x") }
        // A socket file left behind by a crash is replaced.
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = BridgeServer(socketPath: path) { _, _, reply in reply(.success("ok")) }
        try server.start()
        defer { server.stop() }
        #expect(try BridgeClient(socketPath: path).call("x") == "ok")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Suite struct PageRendererTests {
    /// A one-page PDF: a black bar near the top and one near the bottom.
    private func makePDF(at url: URL, pages: Int = 1) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 50, y: 760, width: 495, height: 30))
            context.fill(CGRect(x: 250, y: 40, width: 95, height: 8))
            context.endPDFPage()
        }
        context.closePDF()
    }

    @Test func rendersAndTrims() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("score.pdf")
        try makePDF(at: pdf, pages: 2)

        let full = try PageRenderer.render(pdf: pdf, page: 1, width: 595, trim: false)
        #expect(full.width == 595 && full.height == 842 && full.pageCount == 2 && !full.trimmed)
        #expect(full.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let trimmed = try PageRenderer.render(pdf: pdf, page: 2, width: 595, trim: true, maxGap: 20)
        #expect(trimmed.trimmed)
        // Bars (30 + 8 rows) plus at most 20 rows for each of the three gaps.
        #expect(trimmed.height <= 30 + 8 + 3 * 20 + 2)
        #expect(throws: MCPToolError.self) { try PageRenderer.render(pdf: pdf, page: 3) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct FrescobaldiToolTests {
    private func environment(lilypond: URL? = nil) -> FrescobaldiEnvironment {
        let python = [ProcessInfo.processInfo.environment["PYTHON_LY_DIR"], packageRoot.appendingPathComponent("build/python").path]
            .compactMap { $0 }.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ly/__init__.py").path) }
        return FrescobaldiEnvironment(resources: packageRoot.appendingPathComponent("Resources"),
                                      pythonLyDirectory: python, lilypondSetting: lilypond?.path ?? "/nonexistent")
    }

    private func server(_ environment: FrescobaldiEnvironment, socket: String = socketPath()) -> MCPServer {
        MCPServer(name: "frescobaldi", version: "test",
                  tools: FrescobaldiTools.all(environment: environment, bridge: BridgeClient(socketPath: socket)))
    }

    @Test func listing() async throws {
        let tools = FrescobaldiTools.all(environment: environment())
        #expect(Set(tools.map(\.name)).count == tools.count)
        for tool in tools {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
            #expect(!tool.description.isEmpty)
        }
    }

    @Test func outlineAndTemplates() async throws {
        let server = server(environment())
        let outline = try JSONValue.parse(text(try await call(server, "outline",
                                                              ["text": "\\version \"2.24.0\"\nmelody = { c }\n"])))
        #expect(outline["items"]?.array?.map { $0["title"] } == ["2.24.0", "melody"])
        let list = try JSONValue.parse(text(try await call(server, "templates")))
        #expect(list["templates"] == ["Blank Music Paper", "Choir Hymn", "Lead Sheet"])
        let missing = try await call(server, "templates", ["name": "Opera"])
        #expect(missing["isError"] == true)
    }

    @Test func engraveWithFakeLilyPond() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("lilypond")
        try #"""
        #!/bin/sh
        while [ $# -gt 2 ]; do shift; done
        BASE="$1"; FILE="$2"
        printf '%s\n' "$FILE:2:3: warning: barcheck failed at: 1/2" "  c" "    d |" >&2
        printf '%s\n' "Converting to \`$BASE.pdf'..." >&2
        printf '%%PDF-1.4\n' > "$BASE.pdf"
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let result = try await call(server(environment(lilypond: fake)), "engrave", ["text": "{\n  c d |\n}\n"])
        let report = try JSONValue.parse(text(result))
        #expect(report["status"] == "succeeded" && report["warnings"] == 1 && report["errors"] == 0)
        #expect(report["issues"]?.array?.first?["line"] == 2)
        #expect(report["pdfs"]?.array?.first?.string?.hasSuffix("snippet.pdf") == true)
        #expect(report["source"]?.string?.hasSuffix("snippet.ly") == true)

        let noInput = try await call(server(environment(lilypond: fake)), "engrave")
        #expect(noInput["isError"] == true && text(noInput).contains("path"))
        let noFile = try await call(server(environment(lilypond: fake)), "engrave", ["path": "/nonexistent.ly"])
        #expect(noFile["isError"] == true)

        // An include file engraves its score, into the project's output folder.
        let project = dir.appendingPathComponent("Song")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("music"), withIntermediateDirectories: true)
        try Data("\\include \"music/a.ily\"\n\\score { \\a }".utf8).write(to: project.appendingPathComponent("song.ly"))
        try Data("a = { c }".utf8).write(to: project.appendingPathComponent("music/a.ily"))
        try Data("b = { c }".utf8).write(to: project.appendingPathComponent("music/b.ily"))
        try ProjectSettings(outputDirectory: "build").write(root: project)
        let part = try JSONValue.parse(text(try await call(server(environment(lilypond: fake)), "engrave",
                                                           ["path": .string(project.appendingPathComponent("music/a.ily").path)])))
        #expect(part["source"]?.string?.hasSuffix("Song/song.ly") == true)
        #expect(part["pdfs"]?.array?.first?.string?.hasSuffix("Song/build/song.pdf") == true)
        let unused = try await call(server(environment(lilypond: fake)), "engrave",
                                    ["path": .string(project.appendingPathComponent("music/b.ily").path)])
        #expect(unused["isError"] == true && text(unused).contains("makes no output by itself"))
    }

    @Test func newScore() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = server(environment())
        let folder = dir.appendingPathComponent("Night Music")
        let result = try JSONValue.parse(text(try await call(server, "new_score", [
            "path": .string(folder.path), "ensemble": "string-quartet", "instruments": ["clarinet", "violin", "violin", "viola", "cello"],
            "names": ["", "Violin Solo"], "title": "Nachtmusik", "key": "Eb major", "time": "6/8", "pickup": "8",
            "metronome": "4. = 60", "language": "english", "open": false,
        ])))
        #expect(result["score"]?.string?.hasSuffix("Night Music/night-music.ly") == true)
        #expect(result["opened"] == false)
        #expect(result["files"]?.array?.contains("parts/clarinet.ly") == true)
        #expect(result["players"]?.array?.first?["variables"] == ["clarinet"])
        #expect(result["players"]?.array?[1]["name"] == "Violin Solo")
        let global = try String(contentsOf: folder.appendingPathComponent("music/global.ily"), encoding: .utf8)
        #expect(global.contains("\\key ef \\major") && global.contains("\\time 6/8") && global.contains("\\tempo 4. = 60"))
        #expect(global.contains("\\partial 8 s8 |"))
        let header = try String(contentsOf: folder.appendingPathComponent("header.ily"), encoding: .utf8)
        #expect(header.contains("title = \"Nachtmusik\""))

        // The folder exists now; bad arguments say what's wrong.
        let exists = try await call(server, "new_score", ["path": .string(folder.path), "ensemble": "piano"])
        #expect(exists["isError"] == true && text(exists).contains("isn't empty"))
        let other = dir.appendingPathComponent("Other").path
        for (arguments, message) in [
            (["path": .string(other)], "ensemble"),
            (["path": .string(other), "instruments": ["kazoo"]], "kazoo"),
            (["path": .string(other), "ensemble": "piano", "key": "h major"], "note name"),
            (["path": .string(other), "ensemble": "piano", "time": "3/5"], "time signature"),
            (["path": .string(other), "ensemble": "piano", "time": "3/8", "pickup": "4."], "doesn't fit"),
            (["path": .string(other), "ensemble": "piano", "metronome": "fast"], "metronome"),
        ] as [(JSONValue, String)] {
            let failed = try await call(server, "new_score", arguments)
            #expect(failed["isError"] == true && text(failed).contains(message), "\(arguments): \(text(failed))")
        }
        #expect(!FileManager.default.fileExists(atPath: other))
    }

    @Test func newScoreKeysAndTimes() throws {
        #expect(try NewScoreArguments.key("fis minor") == KeySignature(tonic: Pitch("fis")!, mode: .minor))
        #expect(try NewScoreArguments.key("B♭ major") == KeySignature(tonic: Pitch("bes")!, mode: .major))
        #expect(try NewScoreArguments.key("d aeolian").mode == .minor)
        #expect(try NewScoreArguments.key("G") == KeySignature(tonic: Pitch("g")!, mode: .major))
        #expect(throws: (any Error).self) { try NewScoreArguments.key("fes minor") }
        #expect(try NewScoreArguments.time("C") == TimeSignature(4, 4))
        #expect(try NewScoreArguments.time("¢") == TimeSignature(2, 2))
        #expect(try NewScoreArguments.time("4/4") == TimeSignature(4, 4, symbol: false))
    }

    @Test func transformText() async throws {
        let environment = environment()
        guard environment.pythonLyDirectory != nil else { return } // python-ly not fetched yet
        let server = server(environment)
        let result = try JSONValue.parse(text(try await call(server, "transform", [
            "operation": "transpose", "from": "c", "to": "d", "text": "\\relative c' { c4 e g }",
        ])))
        #expect(result["text"] == "\\relative c' { d4 fis a }" && result["changed"] == true)
        let bad = try await call(server, "transform", ["operation": "transpose", "text": "{ c }"])
        #expect(bad["isError"] == true)
    }

    @Test func documentToolsUseTheBridge() async throws {
        let path = socketPath()
        let bridge = BridgeServer(socketPath: path) { method, params, reply in
            reply(.success(["method": .string(method), "params": params]))
        }
        try bridge.start()
        defer { bridge.stop() }
        let server = server(environment(), socket: path)
        let listed = try JSONValue.parse(text(try await call(server, "list_documents")))
        #expect(listed["method"] == "listDocuments")
        let edited = try JSONValue.parse(text(try await call(server, "edit_document", [
            "document": "doc-1", "edits": [["old_text": "c", "new_text": "d"]],
        ])))
        #expect(edited["method"] == "editDocument" && edited["params"]?["document"] == "doc-1")
        let transformed = try JSONValue.parse(text(try await call(server, "transform", [
            "operation": "reindent", "document": "doc-1",
        ])))
        #expect(transformed["method"] == "transformDocument")
        bridge.stop()
        let offline = try await call(server, "get_document")
        #expect(offline["isError"] == true && text(offline) == Bridge.notRunningMessage)
    }
}
