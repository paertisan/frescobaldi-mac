import Foundation

/// A LilyPond version such as 2.26.0.
public struct LilyPondVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "2.26.0", "2.25.80" or "2.24".
    public init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, !parts.contains(nil) else { return nil }
        self.init(parts[0]!, parts[1]!, parts.count == 3 ? parts[2]! : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// CPU architectures in a Mach-O executable.
public enum MachOArchitecture: String, Sendable, CaseIterable {
    case arm64
    case x86_64
    case other
}

/// Finds the `lilypond` executable and describes it.
public enum LilyPondLocator {
    /// Directories searched after the user setting, in order.
    public static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         fileManager: FileManager = .default) -> [URL] {
        var dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/opt/lilypond/bin",
            "/Applications/LilyPond.app/Contents/Resources/bin",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        dirs.append(home.appendingPathComponent("bin", isDirectory: true))
        // ~/lilypond-2.26.0/bin etc. (the official tarballs), newest first.
        let entries = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let unpacked = entries
            .filter { $0.hasPrefix("lilypond-") }
            .sorted { versionInName($0) ?? LilyPondVersion(0, 0) > versionInName($1) ?? LilyPondVersion(0, 0) }
            .map { home.appendingPathComponent($0, isDirectory: true).appendingPathComponent("bin", isDirectory: true) }
        dirs.append(contentsOf: unpacked)
        return dirs
    }

    /// Candidate executables: the user setting first (a file, or a directory
    /// containing `lilypond`), then `lilypond` in each search directory.
    public static func candidates(userSetting: String? = nil,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  fileManager: FileManager = .default) -> [URL] {
        var result: [URL] = []
        if let setting = userSetting?.trimmingCharacters(in: .whitespacesAndNewlines), !setting.isEmpty {
            let expanded = (setting as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                result.append(URL(fileURLWithPath: expanded).appendingPathComponent("lilypond"))
            } else {
                result.append(URL(fileURLWithPath: expanded))
            }
        }
        result += searchDirectories(home: home, fileManager: fileManager).map { $0.appendingPathComponent("lilypond") }
        return result
    }

    /// The first executable candidate, or nil.
    public static func locate(userSetting: String? = nil,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              fileManager: FileManager = .default) -> URL? {
        candidates(userSetting: userSetting, home: home, fileManager: fileManager).first {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
                && fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    /// Parses the first line of `lilypond --version`:
    /// "GNU LilyPond 2.26.0 (running Guile 3.0)".
    public static func parseVersion(_ output: String) -> LilyPondVersion? {
        let regex = try! NSRegularExpression(pattern: #"GNU LilyPond (\d+\.\d+(?:\.\d+)?)"#)
        let ns = output as NSString
        guard let m = regex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return LilyPondVersion(ns.substring(with: m.range(at: 1)))
    }

    /// Runs `lilypond --version`. Blocks; call off the main thread.
    public static func version(of executable: URL) -> LilyPondVersion? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseVersion(String(decoding: data, as: UTF8.self))
    }

    /// Architectures of the executable after resolving symlinks (Homebrew's
    /// `/opt/homebrew/bin/lilypond` links into the Cellar). Empty for scripts
    /// and non-Mach-O files.
    public static func architectures(of executable: URL) -> [MachOArchitecture] {
        let resolved = executable.resolvingSymlinksInPath()
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return [] }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 4096)) ?? Data()
        return machOArchitectures(header: header)
    }

    /// Reads the CPU types from a Mach-O (thin or universal) header.
    public static func machOArchitectures(header data: Data) -> [MachOArchitecture] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return [] }
        func le32(_ o: Int) -> UInt32 {
            guard o + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func be32(_ o: Int) -> UInt32 {
            guard o + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func arch(_ cpu: UInt32) -> MachOArchitecture {
            switch cpu {
            case 0x0100_000C: return .arm64
            case 0x0100_0007: return .x86_64
            default: return .other
            }
        }

        switch be32(0) {
        case 0xCFFA_EDFE, 0xCEFA_EDFE: // MH_MAGIC_64 / MH_MAGIC, little-endian on disk
            return [arch(le32(4))]
        case 0xCAFE_BABE, 0xCAFE_BABF: // FAT_MAGIC / FAT_MAGIC_64, big-endian
            let is64 = be32(0) == 0xCAFE_BABF
            let count = Int(be32(4))
            // Java class files share 0xCAFEBABE; they have a large "count".
            guard count > 0, count < 32 else { return [] }
            let stride = is64 ? 32 : 20
            return (0..<count).compactMap { i in
                let offset = 8 + i * stride
                return offset + 4 <= bytes.count ? arch(be32(offset)) : nil
            }
        default:
            return []
        }
    }

    static func versionInName(_ name: String) -> LilyPondVersion? {
        let regex = try! NSRegularExpression(pattern: #"(\d+\.\d+(?:\.\d+)?)"#)
        let ns = name as NSString
        guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return LilyPondVersion(ns.substring(with: m.range(at: 1)))
    }
}
