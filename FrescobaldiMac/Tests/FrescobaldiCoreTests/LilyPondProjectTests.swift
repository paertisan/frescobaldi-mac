import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct DocumentVariablesTests {
    @Test func parsesFirstAndLastLines() {
        let text = "\\version \"2.26.0\"\n% -*- master: ../score.ly; indent-width: 4 -*-\n{ c }\n"
        #expect(DocumentVariables.parse(text) == ["master": "../score.ly", "indent-width": "4"])
        let late = Array(repeating: "c4", count: 20).joined(separator: "\n") + "\n% -*- master: main.ly;"
        #expect(DocumentVariables.parse(late)["master"] == "main.ly")
        let middle = (Array(repeating: "c4", count: 6) + ["% -*- master: x.ly;"] + Array(repeating: "d4", count: 6))
            .joined(separator: "\n")
        #expect(DocumentVariables.parse(middle).isEmpty, "only the first and last five lines count")
        let url = URL(fileURLWithPath: "/p/notes/flute.ily")
        #expect(DocumentVariables.master(for: url, text: "% -*- master: ../score.ly;")?.path == "/p/score.ly")
        #expect(DocumentVariables.master(for: url, text: "{ c }") == nil)
    }
}

@Suite struct LilyPondProjectTests {
    /// score.ly → style.ily, notes/global.ily, notes/flute.ily (→ ../defs.ily),
    /// missing.ily, an absolute path, english.ly (system); parts/flute.ly →
    /// ../notes/flute.ily; notes/unused.ily; loop.ily includes itself.
    private func makeProject() throws -> (root: URL, system: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("LilyPondProject-\(UUID().uuidString.prefix(8))")
        let root = base.appendingPathComponent("Song")
        let system = base.appendingPathComponent("ly")
        for dir in ["notes", "parts", "pdf"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        let external = base.appendingPathComponent("font.ily")
        func write(_ path: String, _ text: String, in dir: URL? = nil) throws {
            try Data(text.utf8).write(to: (dir ?? root).appendingPathComponent(path))
        }
        try write("english.ly", "% LilyPond's own", in: system)
        try write("font.ily", "% outside", in: base)
        try write("score.ly", """
            \\version "2.26.0"
            \\include "english.ly"
            \\include "style.ily"
            \\include "notes/global.ily"
            % \\include "commented.ily"
            \\include "notes/flute.ily"
            \\include "missing.ily"
            \\include "\(external.path)"
            \\include "loop.ily"
            """)
        try write("style.ily", "\\paper { }")
        try write("defs.ily", "x = 1")
        try write("loop.ily", "\\include \"loop.ily\"")
        try write("notes/global.ily", "global = { \\time 4/4 }")
        try write("notes/flute.ily", "% -*- master: ../score.ly;\n\\include \"../defs.ily\"\nflute = { c }")
        try write("notes/unused.ily", "x = { }")
        try write("parts/flute.ly", "\\version \"2.26.0\"\n\\include \"../notes/flute.ily\"")
        try write("pdf/score.pdf", "%PDF")
        try write(".hidden.ily", "")
        return (root, system)
    }

    @Test func includeTreeAndProblems() throws {
        let (root, system) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let main = root.appendingPathComponent("score.ly")
        let project = LilyPondProject.load(main: main, systemDirectories: [system])

        let children = project.tree.children
        #expect(children.map(\.written).prefix(4) == ["english.ly", "style.ily", "notes/global.ily", "notes/flute.ily"])
        #expect(children.count == 7, "the commented-out include is ignored")
        #expect(children[0].status == .system)
        #expect(children[3].children.map(\.written) == ["../defs.ily"])
        #expect(children[3].children[0].url?.lastPathComponent == "defs.ily")
        #expect(children[4].status == .missing)
        #expect(children[5].isAbsolute && children[5].isOutsideProject && children[5].status == .ok)
        #expect(children[6].status == .ok && children[6].children.first?.status == .cycle)

        #expect(project.includedPaths.contains(LilyPondProject.normalized(root.appendingPathComponent("defs.ily"))))
        let messages = project.problems.map(\.message)
        #expect(project.problems.first?.severity == .error)
        #expect(messages.contains { $0.hasPrefix("missing.ily wasn't found") })
        #expect(messages.contains { $0.hasPrefix("loop.ily includes itself") })
        #expect(messages.contains("font.ily is included by an absolute path, so the project only builds on this computer. Copy it into the project, or add its folder to the project's include paths."))
        #expect(messages.contains("notes/unused.ily isn't included by any .ly file."))
        #expect(!messages.contains { $0.contains("notes/flute.ily isn't included") }, "parts count too")
        #expect(project.problems.first { $0.message.hasPrefix("missing.ily") }?.line == 7)

        #expect(project.files.map { $0.url.lastPathComponent } ==
                ["notes", "parts", "pdf", "defs.ily", "loop.ily", "score.ly", "style.ily"])
    }

    @Test func mainFile() throws {
        let (root, _) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let flute = root.appendingPathComponent("notes/flute.ily")
        let score = root.appendingPathComponent("score.ly")
        // From the master variable.
        #expect(LilyPondProject.main(for: flute, text: "% -*- master: ../score.ly;").path == score.standardizedFileURL.path)
        // Found by looking for a .ly that includes it.
        let global = root.appendingPathComponent("notes/global.ily")
        #expect(LilyPondProject.normalized(LilyPondProject.main(for: global, text: "global = { }"))
                == LilyPondProject.normalized(score))
        // A .ly is its own main file; an unused include too.
        #expect(LilyPondProject.main(for: score, text: "") == score)
        let unused = root.appendingPathComponent("notes/unused.ily")
        #expect(LilyPondProject.main(for: unused, text: "") == unused)
    }
}
