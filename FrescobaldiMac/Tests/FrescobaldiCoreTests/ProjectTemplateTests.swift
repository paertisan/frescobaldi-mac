import Foundation
import Testing
@testable import FrescobaldiCore

@Suite(.timeLimit(.minutes(2))) struct ProjectTemplateTests {
    @Test func slugs() {
        #expect(ProjectTemplate.slug("My Little Song") == "my-little-song")
        #expect(ProjectTemplate.slug("Für Élise, Op. 59!") == "fur-elise-op-59")
        #expect(ProjectTemplate.slug("???") == "score")
    }

    private func write(_ ensemble: ProjectTemplate.Ensemble, title: String = "Test Piece") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTemplate-\(UUID().uuidString.prefix(8))/\(title)")
        for (path, contents) in ProjectTemplate.files(title: title, ensemble: ensemble, version: LilyPondVersion(2, 26, 0)) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test func layoutAndMasters() throws {
        let files = ProjectTemplate.files(title: "Test Piece", ensemble: .chamberOrchestra,
                                          version: LilyPondVersion(2, 26, 0), paperSize: "letter")
        let paths = files.map(\.path)
        #expect(paths.prefix(3) == ["test-piece.ly", "style.ily", "music/global.ily"])
        #expect(paths.contains("music/clarinet.ily") && paths.contains("parts/clarinet.ly"))
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        #expect(byPath["style.ily"]?.contains("#(set-paper-size \"letter\")") == true)
        #expect(byPath["music/clarinet.ily"]?.contains("\\transposition bes") == true)
        for (path, text) in files {
            #expect(text.hasPrefix("\\version \"2.26.0\""), "\(path)")
            if path.hasSuffix(".ily") {
                let file = URL(fileURLWithPath: "/p/\(path)")
                #expect(DocumentVariables.master(for: file, text: text)?.path == "/p/test-piece.ly", "\(path)")
            }
        }
        #expect(ProjectTemplate.files(title: "Solo", ensemble: .piano, version: nil).map(\.path)
                == ["solo.ly", "style.ily", "music/global.ily", "music/piano.ily"], "no parts for one instrument")
    }

    /// Every generated project is tidy by the project navigator's standards.
    @Test(arguments: ProjectTemplate.Ensemble.allCases)
    func noSuggestions(_ ensemble: ProjectTemplate.Ensemble) throws {
        let root = try write(ensemble)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let project = LilyPondProject.load(main: root.appendingPathComponent("test-piece.ly"))
        #expect(project.problems.isEmpty, "\(project.problems.map(\.message))")
    }

    /// Engraves each generated score (and a part) with the real LilyPond, if installed.
    @Test(.enabled(if: LilyPondLocator.locate() != nil, "LilyPond not installed"),
          arguments: ProjectTemplate.Ensemble.allCases)
    func engraves(_ ensemble: ProjectTemplate.Ensemble) async throws {
        let lilypond = try #require(LilyPondLocator.locate())
        let root = try write(ensemble)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var sources = [root.appendingPathComponent("test-piece.ly")]
        if let part = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("parts").path).sorted().first {
            sources.append(root.appendingPathComponent("parts/\(part)"))
        }
        for source in sources {
            let job = EngraveJob(lilypond: lilypond, source: source)
            let result: EngraveJob.Result = try await withCheckedThrowingContinuation { continuation in
                do {
                    try job.start(output: { _ in }, completion: { continuation.resume(returning: $0) })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #expect(result.succeeded, "\(source.lastPathComponent): \(result.log.suffix(800))")
            #expect(result.messages.isEmpty, "\(source.lastPathComponent): \(result.messages.map(\.message))")
            #expect(!result.pdfs.isEmpty)
        }
    }
}
