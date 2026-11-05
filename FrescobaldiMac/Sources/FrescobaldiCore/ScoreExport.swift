import Foundation

/// Export MIDI and Export MusicXML: LilyPond engraves the score once more
/// in a temporary folder, without printing pages.
///
/// - MIDI: the files the score's `\midi` blocks write. A score without one
///   is engraved again with `fmac-midi.ly`, which adds a `\midi` block
///   (repeats played out), so every score can be exported.
/// - MusicXML: `fmac-export.ly` records the music as LilyPond interprets
///   it, and `MusicXMLWriter` turns that into one file per score.
public final class ScoreExport: @unchecked Sendable {
    public enum Format: String, Sendable, CaseIterable {
        case midi
        case musicXML = "musicxml"

        public var fileExtension: String { self == .midi ? "midi" : "musicxml" }
    }

    public struct Output: Sendable {
        /// The exported files, in the temporary folder: `name.midi`,
        /// `name-1.midi` ... as LilyPond names them, or `name.musicxml`,
        /// `name-2.musicxml` ... for several scores.
        public var files: [URL]
        /// The last LilyPond run (its warnings).
        public var result: EngraveJob.Result
        /// The score had no `\midi` block, so one was added for the export.
        public var addedMIDIBlock: Bool
    }

    public enum Failure: Error, Sendable {
        /// LilyPond failed; the result has its messages.
        case lilypond(EngraveJob.Result)
        /// LilyPond made no score (an empty file, or only markup).
        case noMusic(EngraveJob.Result)
        case cancelled
        case couldNotStart(String)
    }

    public let format: Format
    public let lilypond: URL
    public let source: URL
    /// The project's LilyPond arguments (include folders, its own settings file).
    public let arguments: [String]
    /// The app's Resources/LilyPond folder (fmac-export.ly, fmac-midi.ly).
    public let resources: URL
    /// Where LilyPond writes; the caller removes it when done.
    public let folder: URL
    public let writer: MusicXMLWriter

    private let lock = NSLock()
    private var job: EngraveJob?
    private var wasCancelled = false

    public init(format: Format, lilypond: URL, source: URL, arguments: [String] = [], resources: URL,
                folder: URL? = nil, writer: MusicXMLWriter = MusicXMLWriter()) {
        self.format = format
        self.lilypond = lilypond
        self.source = source
        self.arguments = arguments
        self.resources = resources
        self.folder = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Frescobaldi-export-\(UUID().uuidString)", isDirectory: true)
        self.writer = writer
    }

    public var baseName: String { source.deletingPathExtension().lastPathComponent }

    /// LilyPond arguments that pass `settings` with -dinclude-settings. LilyPond
    /// takes one settings file, so a project's own is included from a small
    /// file that includes both.
    public static func arguments(adding settings: URL, to arguments: [String], folder: URL) throws -> [String] {
        var rest: [String] = []
        var theirs: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-dinclude-settings=") {
                theirs.append(String(argument.dropFirst("-dinclude-settings=".count)))
            } else if argument == "-dinclude-settings", index + 1 < arguments.count {
                theirs.append(arguments[index + 1])
                index += 1
            } else {
                rest.append(argument)
            }
            index += 1
        }
        guard !theirs.isEmpty else { return ["-dinclude-settings=" + settings.path] + rest }
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let text = (theirs + [settings.path]).map { "\\include \(quoted($0))\n" }.joined()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wrapper = folder.appendingPathComponent("fmac-settings.ly")
        try Data(text.utf8).write(to: wrapper)
        return ["-dinclude-settings=" + wrapper.path] + rest
    }

    /// Where to copy exported `files` when the first goes to `destination`:
    /// the others keep their suffix (`score-1.midi` → `Song-1.midi`).
    public static func destinations(for files: [URL], baseName: String, first destination: URL) -> [URL] {
        let folder = destination.deletingLastPathComponent()
        let name = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        return files.enumerated().map { index, file in
            guard index > 0 else { return destination }
            let stem = file.deletingPathExtension().lastPathComponent
            let suffix = stem.hasPrefix(baseName) ? String(stem.dropFirst(baseName.count)) : "-\(index)"
            let named = name + (suffix.isEmpty ? "-\(index)" : suffix)
            return folder.appendingPathComponent(named).appendingPathExtension(ext)
        }
    }

    /// Copies exported files to their destinations, replacing what's there.
    public static func copy(_ files: [URL], baseName: String, to destination: URL,
                            fileManager: FileManager = .default) throws -> [URL] {
        let targets = destinations(for: files, baseName: baseName, first: destination)
        for (file, target) in zip(files, targets) {
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: file, to: target)
        }
        return targets
    }

    public func cancel() {
        let job = lock.withLock { () -> EngraveJob? in
            wasCancelled = true
            return self.job
        }
        job?.cancel()
    }

    private var cancelled: Bool { lock.withLock { wasCancelled } }

    /// Runs the export; `completion` arrives on a private queue.
    public func start(completion: @escaping @Sendable (Result<Output, Failure>) -> Void) {
        switch format {
        case .midi:
            run(settings: nil, environment: [:]) { [self] outcome in
                switch outcome {
                case let .success(result) where !result.midis.isEmpty:
                    completion(.success(Output(files: existing(result.midis), result: result, addedMIDIBlock: false)))
                case .success:
                    // No \midi block: engrave again with one.
                    run(settings: resources.appendingPathComponent("fmac-midi.ly"), environment: [:]) { [self] outcome in
                        switch outcome {
                        case let .success(result):
                            let files = existing(result.midis)
                            completion(files.isEmpty ? .failure(.noMusic(result))
                                       : .success(Output(files: files, result: result, addedMIDIBlock: true)))
                        case let .failure(failure):
                            completion(.failure(failure))
                        }
                    }
                case let .failure(failure):
                    completion(.failure(failure))
                }
            }
        case .musicXML:
            let events = folder.appendingPathComponent("events.txt")
            run(settings: resources.appendingPathComponent("fmac-export.ly"),
                environment: ["FMAC_EXPORT_EVENTS": events.path]) { [self] outcome in
                switch outcome {
                case let .success(result):
                    let text = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
                    let documents = writer.documents(ScoreEvents(parsing: text))
                    guard !documents.isEmpty else { completion(.failure(.noMusic(result))); return }
                    do {
                        var files: [URL] = []
                        for (index, document) in documents.enumerated() {
                            let name = index == 0 ? baseName : "\(baseName)-\(index + 1)"
                            let url = folder.appendingPathComponent(name).appendingPathExtension("musicxml")
                            try Data(document.utf8).write(to: url)
                            files.append(url)
                        }
                        completion(.success(Output(files: files, result: result, addedMIDIBlock: false)))
                    } catch {
                        completion(.failure(.couldNotStart(error.localizedDescription)))
                    }
                case let .failure(failure):
                    completion(.failure(failure))
                }
            }
        }
    }

    private func existing(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func run(settings: URL?, environment: [String: String],
                     completion: @escaping @Sendable (Result<EngraveJob.Result, Failure>) -> Void) {
        guard !cancelled else { completion(.failure(.cancelled)); return }
        let job: EngraveJob
        do {
            var arguments = ["-dno-print-pages"] + self.arguments
            if let settings { arguments = try Self.arguments(adding: settings, to: arguments, folder: folder) }
            job = EngraveJob(lilypond: lilypond, source: source,
                             outputBase: folder.appendingPathComponent(baseName), mode: .publish,
                             extraArguments: arguments, extraEnvironment: environment)
            lock.withLock { self.job = job }
            defer { if cancelled { job.cancel() } }
            try job.start(output: { _ in }, completion: { result in
                if result.cancelled {
                    completion(.failure(.cancelled))
                } else if !result.succeeded {
                    completion(.failure(.lilypond(result)))
                } else {
                    completion(.success(result))
                }
            })
        } catch {
            completion(.failure(.couldNotStart(error.localizedDescription)))
        }
    }
}
