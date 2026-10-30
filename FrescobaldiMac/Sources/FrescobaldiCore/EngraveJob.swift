import Foundation

/// One LilyPond run: `lilypond -dpoint-and-click --pdf -o <dir/base> <file>`.
///
/// Callbacks arrive on a private serial queue; UI code hops to the main
/// queue itself.
public final class EngraveJob: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Point-and-click links on, for editing.
        case preview
        /// No point-and-click links, for sharing.
        case publish
    }

    public struct Result: Sendable {
        public var exitStatus: Int32
        public var cancelled: Bool
        public var log: String
        public var messages: [LilyPondMessage]
        /// PDFs and MIDI files LilyPond wrote, in the order it reported them.
        public var pdfs: [URL]
        public var midis: [URL]
        public var duration: TimeInterval

        public var succeeded: Bool { !cancelled && exitStatus == 0 }
    }

    public let lilypond: URL
    public let source: URL
    /// Directory and base name for output files (`-o`).
    public let outputBase: URL
    public let mode: Mode
    public let extraArguments: [String]

    /// Delivers output and completion in order.
    private let queue = DispatchQueue(label: "EngraveJob")
    /// Guards `process` and `wasCancelled`, so `cancel()` works from any
    /// thread, including inside the callbacks.
    private let lock = NSLock()
    private var process: Process?
    /// `run()` has returned; before that, `terminate()` isn't safe.
    private var launched = false
    private var finished = false
    private var wasCancelled = false
    private var log = Data()
    private var started: Date?

    public init(lilypond: URL, source: URL, outputBase: URL? = nil, mode: Mode = .preview,
                extraArguments: [String] = []) {
        self.lilypond = lilypond
        self.source = source
        self.outputBase = outputBase ?? source.deletingPathExtension()
        self.mode = mode
        self.extraArguments = extraArguments
    }

    /// Arguments passed to `lilypond`.
    public var arguments: [String] {
        [mode == .preview ? "-dpoint-and-click" : "-dno-point-and-click", "--pdf"]
            + extraArguments
            + ["-o", outputBase.path, source.path]
    }

    /// The environment for LilyPond: English messages (so the log parser
    /// works) and a PATH that includes Homebrew for its helper programs.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["LANG"] = "en_US.UTF-8"
        env["LANGUAGE"] = "en"
        env.removeValue(forKey: "LC_ALL")
        env.removeValue(forKey: "LC_MESSAGES")
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for dir in extra.reversed() where !path.contains(dir) { path.insert(dir, at: 0) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Starts LilyPond. `output` receives log text as it arrives.
    public func start(output: @escaping @Sendable (String) -> Void,
                      completion: @escaping @Sendable (Result) -> Void) throws {
        let process = Process()
        process.executableURL = lilypond
        process.arguments = arguments
        process.environment = Self.environment()
        process.currentDirectoryURL = source.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let reader = pipe.fileHandleForReading
        let finished = DispatchGroup()
        finished.enter() // end of output
        finished.enter() // process exit
        process.terminationHandler = { _ in finished.leave() }

        try FileManager.default.createDirectory(at: outputBase.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        lock.withLock { self.process = process }
        started = Date()
        do {
            try process.run()
        } catch {
            lock.withLock { self.process = nil }
            throw error
        }
        // Read on a plain thread with blocking reads. (readabilityHandler
        // mixed up handlers between concurrent jobs on Linux Foundation.)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                queue.async {
                    self.log.append(data)
                    output(String(decoding: data, as: UTF8.self))
                }
            }
            finished.leave()
        }
        // Output can arrive (and `cancel()` be called) before `run()` returns.
        lock.withLock {
            launched = true
            if wasCancelled { stop(process) }
        }

        finished.notify(queue: queue) { [self] in
            let text = String(decoding: log, as: UTF8.self)
            let directory = process.currentDirectoryURL ?? source.deletingLastPathComponent()
            let outputs = LilyPondLogParser.outputFiles(in: text).map {
                URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL
            }
            let result = Result(
                exitStatus: process.terminationStatus,
                cancelled: lock.withLock { wasCancelled },
                log: text,
                messages: LilyPondLogParser.parse(text),
                pdfs: outputs.filter { $0.pathExtension.lowercased() == "pdf" },
                midis: outputs.filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) },
                duration: Date().timeIntervalSince(started ?? Date()))
            lock.withLock {
                self.process = nil
                self.finished = true
            }
            completion(result)
        }
    }

    public var isRunning: Bool { lock.withLock { process != nil && !finished } }

    /// Stops LilyPond. Safe from any thread, also before it has fully started.
    public func cancel() {
        lock.withLock {
            guard let process, !finished, !wasCancelled else { return }
            wasCancelled = true
            if launched { stop(process) }
        }
    }

    /// SIGTERM, then SIGKILL if LilyPond is still running 3 seconds later.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let stillRunning = self.lock.withLock { !self.finished && self.process === process }
            if stillRunning { kill(pid, SIGKILL) }
        }
    }
}

extension EngraveJob {
    /// Output files an earlier run left next to `source`, if they're at least
    /// as new as it. Same rule as Frescobaldi's resultfiles: `name.ext`, then
    /// `name-*[0-9].ext` (several `\book` blocks give `name-1.pdf`,
    /// `name-2.pdf`, …) in natural order. Looks in `outputDirectory` instead
    /// if the project has one.
    public static func existingOutputs(for source: URL, outputDirectory: URL? = nil,
                                       fileManager: FileManager = .default) -> (pdfs: [URL], midis: [URL]) {
        let directory = outputDirectory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        func modified(_ path: String) -> Date? {
            (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        guard let sourceDate = modified(source.path),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return ([], []) }

        let matches = names.filter { name in
            let stem = (name as NSString).deletingPathExtension
            guard stem == base || (stem.hasPrefix(base + "-") && stem.last.map { ("0"..."9").contains($0) } == true)
            else { return false }
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let date = modified(path) else { return false }
            return date >= sourceDate
        }
        .sorted { a, b in
            let aIsBase = (a as NSString).deletingPathExtension == base
            let bIsBase = (b as NSString).deletingPathExtension == base
            if aIsBase != bIsBase { return aIsBase }
            return a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
        .map { directory.appendingPathComponent($0) }

        func withExtensions(_ extensions: Set<String>) -> [URL] {
            matches.filter { extensions.contains($0.pathExtension.lowercased()) }
        }
        return (withExtensions(["pdf"]), withExtensions(["mid", "midi"]))
    }
}
