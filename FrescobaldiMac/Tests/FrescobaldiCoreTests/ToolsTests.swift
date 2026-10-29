import Foundation
import Testing
@testable import FrescobaldiCore

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// python-ly for the tests: $PYTHON_LY_DIR, or the copy that
/// scripts/build-app.sh downloads into build/python.
private func pythonLyTool() -> PythonLyTool? {
    let candidates = [ProcessInfo.processInfo.environment["PYTHON_LY_DIR"],
                      packageRoot.appendingPathComponent("build/python").path].compactMap { $0 }
    guard let dir = candidates.first(where: {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("ly/__init__.py").path)
    }), let python = PythonLyTool.findPython() else { return nil }
    return PythonLyTool(pythonLyDirectory: URL(fileURLWithPath: dir),
                        driverScript: packageRoot.appendingPathComponent("Resources/python/fmac_lytool.py"),
                        python: python)
}

@Suite struct PythonLyToolTests {
    @Test(.enabled(if: pythonLyTool() != nil, "python-ly not found; set PYTHON_LY_DIR"))
    func transposeWholeDocument() throws {
        let tool = try #require(pythonLyTool())
        let source = "\\version \"2.24.0\"\n\\language \"english\"\n{ c4 d e fs }\n"
        let result = try tool.apply(.transpose(from: "c", to: "d"), to: source)
        #expect(result == "\\version \"2.24.0\"\n\\language \"english\"\n{ d4 e fs gs }\n")
    }

    @Test(.enabled(if: pythonLyTool() != nil, "python-ly not found; set PYTHON_LY_DIR"))
    func selectionUsesUTF16Offsets() throws {
        let tool = try #require(pythonLyTool())
        let source = "\\header { title = \"🎵\" }\n{ c4 d e }\n"
        let selection = (source as NSString).range(of: "c4 d")
        let result = try tool.apply(.transpose(from: "c", to: "d"), to: source, selection: selection)
        #expect(result == "\\header { title = \"🎵\" }\n{ d4 e e }\n")
    }

    @Test(.enabled(if: pythonLyTool() != nil, "python-ly not found; set PYTHON_LY_DIR"))
    func otherEdits() throws {
        let tool = try #require(pythonLyTool())
        #expect(try tool.apply(.translate(language: "english"), to: "{ cis4 }") == "\\language \"english\"\n{ cs4 }")
        #expect(try tool.apply(.relativeToAbsolute, to: "\\relative c' { c4 e g c }") == "{ c'4 e' g' c'' }")
        #expect(try tool.apply(.absoluteToRelative, to: "{ c'4 e' g' c'' }") == "\\relative c' { c4 e g c }")
        #expect(try tool.apply(.simplifyAccidentals, to: "{ eis4 }") == "{ f4 }")
        #expect(try tool.apply(.indent, to: "{\nc4\n}", indentWidth: 4) == "{\n    c4\n}")
        #expect(throws: PythonLyError.failed("not a pitch: x")) {
            try tool.apply(.transpose(from: "x", to: "d"), to: "{ c }")
        }
    }

    @Test func scalarOffsets() {
        let text = "a🎵b" as NSString
        #expect(PythonLyTool.scalarOffset(ofUTF16: 0, in: text) == 0)
        #expect(PythonLyTool.scalarOffset(ofUTF16: 3, in: text) == 2)
        #expect(PythonLyTool.scalarOffset(ofUTF16: 99, in: text) == 3)
    }
}

@Suite struct TextReplacementTests {
    @Test func minimalReplacement() {
        #expect(TextReplacement.between("abc", "abc") == nil)
        #expect(TextReplacement.between("{ c4 d }", "{ d4 e }")
                == TextReplacement(range: NSRange(location: 2, length: 4), replacement: "d4 e"))
        #expect(TextReplacement.between("ab", "abc") == TextReplacement(range: NSRange(location: 2, length: 0), replacement: "c"))
        #expect(TextReplacement.between("abc", "") == TextReplacement(range: NSRange(location: 0, length: 3), replacement: ""))
        #expect(TextReplacement.between("aa", "aaa") == TextReplacement(range: NSRange(location: 2, length: 0), replacement: "a"))
    }

    @Test func keepsSurrogatePairsWhole() throws {
        // 😀 = D83D DE00, 😁 = D83D DE01: they share the high surrogate.
        let r = try #require(TextReplacement.between("x😀y", "x😁y"))
        #expect(r.range == NSRange(location: 1, length: 2))
        #expect(r.replacement == "😁")
    }

    @Test(arguments: 0..<200)
    func applyingGivesNewText(seed: Int) throws {
        var rng = SplitMix64(seed: UInt64(seed))
        let alphabet = ["a", "b", "🎵", "é", "\n", " "]
        func random() -> String { (0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined() }
        let old = random(), new = random()
        guard let r = TextReplacement.between(old, new) else {
            #expect(old == new)
            return
        }
        #expect((old as NSString).replacingCharacters(in: r.range, with: r.replacement) == new)
    }
}

@Suite(.timeLimit(.minutes(1))) struct EngraveJobTests {
    @Test func arguments() {
        let job = EngraveJob(lilypond: URL(fileURLWithPath: "/opt/homebrew/bin/lilypond"),
                             source: URL(fileURLWithPath: "/Users/me/Song.ly"))
        #expect(job.arguments == ["-dpoint-and-click", "--pdf", "-o", "/Users/me/Song", "/Users/me/Song.ly"])
        let publish = EngraveJob(lilypond: URL(fileURLWithPath: "/x"), source: URL(fileURLWithPath: "/a/b.ly"),
                                 outputBase: URL(fileURLWithPath: "/tmp/out/b"), mode: .publish)
        #expect(publish.arguments == ["-dno-point-and-click", "--pdf", "-o", "/tmp/out/b", "/a/b.ly"])
    }

    @Test func environment() {
        let env = EngraveJob.environment(base: ["PATH": "/usr/bin:/bin", "LC_ALL": "de_DE.UTF-8", "LANG": "de_DE"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(env["LANG"] == "en_US.UTF-8" && env["LC_ALL"] == nil && env["LANGUAGE"] == "en")
        #expect(EngraveJob.environment(base: ["PATH": "/usr/local/bin:/usr/bin"])["PATH"]
                == "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    /// Runs a stand-in for lilypond that prints a realistic log and writes a PDF.
    @Test func runsAndCollectsResults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EngraveJob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("lilypond")
        try #"""
        #!/bin/sh
        # args: -dpoint-and-click --pdf -o BASE FILE
        BASE="$4"; FILE="$5"
        say() { printf '%s\n' "$1" >&2; }
        say "GNU LilyPond 2.26.0 (running Guile 3.0)"
        say "Processing \`$FILE'"
        say "$FILE:2:3: error: unknown escaped string: \\foo"
        say "  c"
        say "    \\foo d"
        say "Converting to \`$BASE.pdf'..."
        printf '%%PDF-1.4\n' > "$BASE.pdf"
        say "MIDI output to \`$BASE.midi'..."
        exit 1
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let source = dir.appendingPathComponent("song.ly")
        try "{\n  c \\foo d\n}\n".write(to: source, atomically: true, encoding: .utf8)

        let job = EngraveJob(lilypond: fake, source: source, outputBase: dir.appendingPathComponent("out/song"))
        let streamed = StreamedText()
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { streamed.append($0) }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(result.exitStatus == 1 && !result.succeeded && !result.cancelled)
        #expect(result.messages.count == 1)
        #expect(result.messages.first?.line == 2 && result.messages.first?.column == 3)
        #expect(result.messages.first?.context == ["  c", "    \\foo d"])
        #expect(result.pdfs.map(\.lastPathComponent) == ["song.pdf"])
        #expect(result.midis.map(\.lastPathComponent) == ["song.midi"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out/song.pdf").path))
        #expect(streamed.text == result.log)
    }

    @Test func cancel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EngraveJob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("lilypond")
        try "#!/bin/sh\necho started\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let job = EngraveJob(lilypond: fake, source: dir.appendingPathComponent("x.ly"))
        let start = Date()
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { _ in job.cancel() }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(result.cancelled)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

private final class StreamedText: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ s: String) { lock.lock(); storage += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite struct TemplateTests {
    @Test func render() {
        let (text, cursor) = LilyPondTemplate.render("\\version \"$LILYPOND_VERSION\"\n🎵 { $CURSOR }\n$CURSOR",
                                                     version: LilyPondVersion(2, 26, 0))
        #expect(text == "\\version \"2.26.0\"\n🎵 {  }\n")
        #expect(cursor == ("\\version \"2.26.0\"\n🎵 { " as NSString).length)
        #expect(LilyPondTemplate.render("x", version: nil) == ("x", 0))
    }

    @Test func bundledTemplates() throws {
        let templates = LilyPondTemplate.templates(in: packageRoot.appendingPathComponent("Resources/Templates"))
        #expect(templates.map(\.name) == ["Blank Music Paper", "Choir Hymn", "Lead Sheet"])
        for template in templates {
            let (text, _) = try template.render(version: LilyPondVersion(2, 26, 0))
            #expect(!text.contains("$"), "\(template.name)")
            #expect(text.contains("\\version \"2.26.0\""))
        }
    }
}

@Suite struct PointAndClickIndexTests {
    @Test func lookup() {
        var index = PointAndClickIndex<String>()
        index.add(TextEditLink(path: "/a/song.ly", line: 3, startColumn: 2, endColumn: 5), "c")
        index.add(TextEditLink(path: "/a/song.ly", line: 3, startColumn: 6, endColumn: 7), "d")
        index.add(TextEditLink(path: "/a/song.ly", line: 3, startColumn: 6, endColumn: 7), "d-page2")
        index.add(TextEditLink(path: "/a/other.ly", line: 3, startColumn: 0, endColumn: 9), "other")
        #expect(index.items(path: "/a/song.ly", line: 3, column: 3) == ["c"])
        #expect(index.items(path: "/a/./song.ly", line: 3, column: 5) == ["c"])
        #expect(index.items(path: "/a/song.ly", line: 3, column: 0) == ["c"], "next note when none covers")
        #expect(index.items(path: "/a/song.ly", line: 3, column: 6) == ["d", "d-page2"])
        #expect(index.items(path: "/a/song.ly", line: 3, column: 9) == [])
        #expect(index.items(path: "/a/song.ly", line: 4, column: 0) == [])
    }
}

@Suite struct TextEditingTests {
    private func apply(_ edit: TextEditing.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func toggleComment() {
        let text = "{\n  c4 d\n\n    e f\n}\n"
        let selection = (text as NSString).range(of: "c4 d\n\n    e")
        let commented = TextEditing.toggleComment(selection: selection, in: text as NSString)
        let once = apply(commented, to: text)
        #expect(once == "{\n  % c4 d\n\n  %   e f\n}\n")
        let back = TextEditing.toggleComment(selection: commented.selection, in: once as NSString)
        #expect(apply(back, to: once) == text)
    }

    @Test func selectionEndingAtLineStartExcludesThatLine() {
        let text = "a\nb\nc" as NSString
        let block = TextEditing.lineBlock(for: NSRange(location: 0, length: 2), in: text)
        #expect(block == NSRange(location: 0, length: 1))
        #expect(TextEditing.lineBlock(for: NSRange(location: 4, length: 0), in: text) == NSRange(location: 4, length: 1))
    }

    @Test func shift() {
        let text = "a\n  b\n\tc\n"
        let all = NSRange(location: 0, length: (text as NSString).length)
        #expect(apply(TextEditing.shift(selection: all, in: text as NSString, right: true), to: text)
                == "  a\n    b\n  \tc\n")
        #expect(apply(TextEditing.shift(selection: all, in: text as NSString, right: false), to: text)
                == "a\nb\nc\n")
    }

    @Test func autoIndent() {
        let text = "  \\score {  % comment\n    c\n" as NSString
        #expect(TextEditing.newlineInsertion(at: 21, in: text) == "\n    ")
        #expect(TextEditing.newlineInsertion(at: text.length - 1, in: text) == "\n    ")
        #expect(TextEditing.newlineInsertion(at: 2, in: "  << x" as NSString) == "\n  ")
        #expect(TextEditing.newlineInsertion(at: 4, in: "  <<" as NSString) == "\n    ")
    }

    @Test func dedentForClosing() {
        let text = "{\n    " as NSString
        let edit = TextEditing.dedentForClosing(at: text.length, in: text)
        #expect(edit?.range == NSRange(location: 4, length: 2))
        #expect(TextEditing.dedentForClosing(at: 4, in: "{\n c" as NSString) == nil)
        #expect(TextEditing.dedentForClosing(at: 2, in: "{\n" as NSString) == nil)
    }
}

@Suite struct LineIndexTests {
    @Test func lines() {
        let index = LineIndex("ab\r\ncd\n\nlast" as NSString)
        #expect(index.starts == [0, 4, 7, 8])
        #expect(index.lineCount == 4)
        #expect(index.line(at: 0) == 0 && index.line(at: 3) == 0 && index.line(at: 4) == 1)
        #expect(index.line(at: 7) == 2 && index.line(at: 12) == 3)
        #expect(index.range(ofLine: 0) == NSRange(location: 0, length: 4))
        #expect(index.range(ofLine: 3) == NSRange(location: 8, length: 4))
        #expect(LineIndex("" as NSString).range(ofLine: 0) == NSRange(location: 0, length: 0))
        #expect(LineIndex("x\n" as NSString).starts == [0, 2])
    }

    @Test func largeText() {
        let text = String(repeating: "c4 d e f\n", count: 5000) as NSString
        let index = LineIndex(text)
        #expect(index.lineCount == 5001)
        #expect(index.line(at: 9 * 2500 + 3) == 2500)
    }
}
