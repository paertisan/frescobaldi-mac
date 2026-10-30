import Foundation
import Testing
@testable import FrescobaldiCore

@Suite struct TopLevelTests {
    private func output(_ text: String) -> Bool { DocumentOutline.topLevel(in: text as NSString).producesOutput }

    @Test func scoresBooksMarkupAndMusicMakeOutput() {
        #expect(output("\\version \"2.26.0\"\n\\score { { c'4 } }"))
        #expect(output("\\book { \\score { { c } } }"))
        #expect(output("\\markup \\bold \"Title page\""))
        #expect(output("{ c'4 d' e' }"))
        #expect(output("<< \\new Staff { c } >>"))
        #expect(output("\\relative c' { c d e }"))
        #expect(output("\\new PianoStaff << >>"))
        #expect(output("melody = { c d }\n\\melody"), "a variable on its own is an implicit score")
        #expect(output("\\header { title = \"x\" }\n\\include \"defs.ily\"\n\\score { \\melody }"))
    }

    @Test func definitionsAndSettingsDont() {
        #expect(!output(""))
        #expect(!output("\\version \"2.26.0\"\n\\language \"english\"\n\\include \"defs.ily\""))
        #expect(!output("flute = \\relative c'' {\n  c4 d e f\n}\n\nglobal = { \\key c \\major \\time 4/4 }"))
        #expect(!output("\\header { title = \"Song\" }\n\\paper { indent = 0 }\n\\layout {\n  \\context { \\Staff }\n}"))
        #expect(!output("#(set-global-staff-size 18)\n\\pointAndClickOff"))
        #expect(!output("myScore = \\score { { c } }\nfooter = \\markup \\italic \"x\""))
        #expect(!output("staff = \\new Staff \\with {\n  instrumentName = \"Vl\"\n} \\violin"))
        #expect(!output("upper = \\relative c'' {\n  \\clef treble\n  c4 d e f\n}\n% -*- master: ../score.ly;"))
        #expect(!output("fn = #(define-music-function (m) (ly:music?)\n  #{ \\relative { $m } #})"))
        #expect(!output("% only a comment { c d e }\n%{ { c } %}"))
    }

    @Test func includesAndWhereTheyAre() {
        let summary = DocumentOutline.topLevel(in: """
            \\include "style.ily"
            music = { \\include "notes.ily" }
            \\book {
              \\include "movement-1.ly"
              \\score { \\include "inner.ily" }
            }
            """ as NSString)
        #expect(summary.includes.map(\.path) == ["style.ily", "notes.ily", "movement-1.ly", "inner.ily"])
        #expect(summary.includes.map(\.isSection) == [true, false, true, false])
        #expect(summary.includes.map(\.line) == [1, 2, 4, 5])
    }
}

@Suite struct ProjectSettingsTests {
    @Test func roundTripLeavesOutWhatIsntSet() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Settings-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ProjectSettings(defaultTarget: "score.ly", includePaths: ["lib"], outputDirectory: "build",
                                       commands: [ProjectCommand(name: "Parts", command: "make parts")])
        try settings.write(root: root)
        let text = try String(contentsOf: root.appendingPathComponent("frescobaldi.json"), encoding: .utf8)
        #expect(!text.contains("targets"), "unset targets stay automatic")
        #expect(text.contains("\"outputDirectory\" : \"build\""))
        #expect(try ProjectSettings.load(root: root) == settings)
        #expect(ProjectSettings.root(containing: root.appendingPathComponent("music/deep")) == root.standardizedFileURL)
        #expect(settings.lilypondArguments(root: root) == ["-I", root.appendingPathComponent("lib").path])
        #expect(settings.outputBase(for: root.appendingPathComponent("parts/flute.ly"), root: root)?.path
                == root.appendingPathComponent("build/flute").path)
        #expect(try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8)) == ProjectSettings())
    }

    @Test func portablePaths() {
        let root = URL(fileURLWithPath: "/work/songs/Song")
        func path(_ p: String) -> String { ProjectSettings.portablePath(for: URL(fileURLWithPath: p), root: root) }
        #expect(path("/work/songs/Song/lib") == "lib")
        #expect(path("/work/songs/lib") == "../lib")
        #expect(path("/work/lib/oll") == "../../lib/oll")
        #expect(path("/work/songs") == "..")
        #expect(path("/opt/lilypond") == "/opt/lilypond")
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(path(home.appendingPathComponent("ly/oll").path) == "~/ly/oll")
    }
}

@Suite struct ProjectTargetsTests {
    /// The layout File > New Project makes, plus a book that includes the
    /// score, a scratch .ly with only definitions, a library folder and an
    /// .ily that nothing includes.
    private func makeProject(settings: ProjectSettings? = nil) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("Targets-\(UUID().uuidString.prefix(8))")
        let root = base.appendingPathComponent("Song")
        for dir in ["music", "parts", "build"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: base.appendingPathComponent("lib"), withIntermediateDirectories: true)
        func write(_ path: String, _ text: String, in dir: URL? = nil) throws {
            try Data(text.utf8).write(to: (dir ?? root).appendingPathComponent(path))
        }
        try write("score.ly", "\\version \"2.26.0\"\n\\include \"style.ily\"\n\\include \"music/flute.ily\"\n\\score { \\flute }")
        try write("book.ly", "\\version \"2.26.0\"\n\\book {\n  \\include \"score.ly\"\n}")
        try write("defs.ly", "\\version \"2.26.0\"\nx = { c }")
        try write("style.ily", "\\include \"house.ily\"\n\\paper { }")
        try write("music/flute.ily", "flute = \\relative { c'' }")
        try write("music/notes.ly", "\\relative { c' d e }")
        try write("music/sketch.ily", "y = { }")
        try write("parts/flute.ly", "\\version \"2.26.0\"\n\\include \"../style.ily\"\n\\include \"../music/flute.ily\"\n\\score { \\flute }\n\\score { \\include \"../music/notes.ly\" }")
        try write("house.ily", "% house style", in: base.appendingPathComponent("lib"))
        if let settings { try settings.write(root: root) }
        return root
    }

    private func names(_ urls: [URL], _ root: URL) -> [String] { urls.map { LilyPondProject.relativePath($0, to: root) } }

    @Test func findsTargetsAndWhatToEngrave() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let score = LilyPondProject.open(root.appendingPathComponent("score.ly"))
        // defs.ly makes no output; music/notes.ly is only used inside a \score.
        #expect(names(score.targets, root) == ["book.ly", "score.ly", "parts/flute.ly"])
        #expect(score.target == score.file)

        let flute = LilyPondProject.open(root.appendingPathComponent("music/flute.ily"))
        #expect(flute.root.path == root.standardizedFileURL.path)
        #expect(flute.target.map { LilyPondProject.relativePath($0, to: root) } == "book.ly",
                "the first target (in menu order) that includes it")
        #expect(flute.main == flute.target)

        let part = LilyPondProject.open(root.appendingPathComponent("parts/flute.ly"))
        #expect(part.root.path == root.standardizedFileURL.path, "parts include ../ files, so the project is one level up")
        #expect(part.target == part.file)

        let notes = LilyPondProject.open(root.appendingPathComponent("music/notes.ly"))
        #expect(notes.target.map { LilyPondProject.relativePath($0, to: root) } == "parts/flute.ly")

        let defs = LilyPondProject.open(root.appendingPathComponent("defs.ly"))
        #expect(defs.target == nil)
        #expect(defs.problems.contains { $0.message.hasPrefix("defs.ly makes no output by itself") })

        let sketch = LilyPondProject.open(root.appendingPathComponent("music/sketch.ily"))
        #expect(sketch.target == nil)
        #expect(sketch.root.path == root.standardizedFileURL.path)
        #expect(sketch.problems.contains { $0.message == "music/sketch.ily isn't included by any .ly file." })

        // house.ily isn't found without the include path.
        #expect(score.problems.contains { $0.message == "house.ily wasn't found." })
    }

    @Test func settingsChooseTargetsIncludePathsAndOutput() throws {
        let settings = ProjectSettings(targets: ["score.ly", "parts/flute.ly", "gone.ly"], defaultTarget: "parts/flute.ly",
                                       includePaths: ["../lib", "missing"], outputDirectory: "build")
        let root = try makeProject(settings: settings)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let flute = LilyPondProject.open(root.appendingPathComponent("music/flute.ily"))
        #expect(flute.settings == settings)
        #expect(names(flute.targets, root) == ["score.ly", "parts/flute.ly"])
        #expect(flute.target.map { LilyPondProject.relativePath($0, to: root) } == "parts/flute.ly", "the default target")
        let messages = flute.problems.map(\.message)
        #expect(messages.contains("frescobaldi.json lists the target gone.ly, which doesn't exist."))
        #expect(messages.contains("The include path missing isn't a folder."))
        #expect(!messages.contains { $0.hasPrefix("house.ily") }, "found in ../lib, and not 'outside the project'")
        let house = flute.tree.children.first { $0.written == "../style.ily" }?.children.first
        #expect(house?.status == .ok && house?.isFromIncludePath == true)

        let options = flute.engraveOptions(for: root.appendingPathComponent("parts/flute.ly"))
        #expect(options.outputBase?.path == root.appendingPathComponent("build/flute").standardizedFileURL.path)
        #expect(options.arguments.first == "-I")

        // Existing output is looked up in the output folder.
        let pdf = root.appendingPathComponent("build/flute.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        let found = EngraveJob.existingOutputs(for: root.appendingPathComponent("parts/flute.ly"),
                                               outputDirectory: flute.outputDirectory)
        #expect(found.pdfs.map(\.lastPathComponent) == ["flute.pdf"])
    }

    @Test func brokenSettingsFileIsReported() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("{ \"targets\": 3 }".utf8).write(to: root.appendingPathComponent("frescobaldi.json"))
        let project = LilyPondProject.open(root.appendingPathComponent("score.ly"))
        #expect(project.problems.first?.severity == .error)
        #expect(project.problems.first?.message.hasPrefix("frescobaldi.json couldn't be read") == true)
        #expect(names(project.targets, root) == ["book.ly", "score.ly", "parts/flute.ly"], "falls back to finding them")
    }
}

@Suite struct BuildLogTests {
    @Test func followsMakeAndLilyPondDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BuildLog-\(UUID().uuidString.prefix(8))")
        for dir in ["parts", "build", "music"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data().write(to: base.appendingPathComponent("music/flute.ily"))
        let log = """
            make -C parts
            make[1]: Entering directory '\(base.path)/parts'
            lilypond flute.ly
            ../music/flute.ily:2:29: error: unknown command: `\\foo'
            flute = \\relative { c'' d e
                                        \\foo }
            Converting to `flute.pdf'...
            make[1]: Leaving directory '\(base.path)/parts'
            Changing working directory to: `\(base.path)/build'
            Converting to `score.pdf'...
            """
        let messages = LilyPondLogParser.resolvingPaths(LilyPondLogParser.parse(log), in: log, base: base)
        #expect(messages.map(\.file) == [base.appendingPathComponent("music/flute.ily").standardizedFileURL.path])
        #expect(messages.first?.context.count == 2)
        #expect(LilyPondLogParser.outputFiles(in: log, base: base).map { LilyPondProject.relativePath($0, to: base) }
                == ["parts/flute.pdf", "build/score.pdf"])
    }

    @Test func runsACommand() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Command-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let job = EngraveJob(command: "echo \"x.ly:1:2: warning: hi\"; pwd; exit 3", directory: base)
        let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(result.exitStatus == 3)
        #expect(result.messages.first?.file == base.appendingPathComponent("x.ly").standardizedFileURL.path)
        #expect(result.log.contains(base.lastPathComponent))
    }
}
