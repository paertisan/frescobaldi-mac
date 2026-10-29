import Foundation
import Testing
@testable import FrescobaldiCore

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrescobaldiCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func machOHeader(cpu: UInt32) -> Data {
    var bytes: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE] // MH_MAGIC_64, little-endian
    bytes += withUnsafeBytes(of: cpu.littleEndian, Array.init)
    bytes += [UInt8](repeating: 0, count: 24)
    return Data(bytes)
}

private func fatHeader(cpus: [UInt32]) -> Data {
    var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    bytes += withUnsafeBytes(of: UInt32(cpus.count).bigEndian, Array.init)
    for cpu in cpus {
        bytes += withUnsafeBytes(of: cpu.bigEndian, Array.init)
        bytes += [UInt8](repeating: 0, count: 16)
    }
    return Data(bytes)
}

private func makeExecutable(_ url: URL, contents: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Suite struct LilyPondLocatorTests {
    @Test func parsesVersion() {
        #expect(LilyPondLocator.parseVersion("GNU LilyPond 2.26.0 (running Guile 3.0)\n\nCopyright")
                == LilyPondVersion(2, 26, 0))
        #expect(LilyPondLocator.parseVersion("GNU LilyPond 2.25.80") == LilyPondVersion(2, 25, 80))
        #expect(LilyPondLocator.parseVersion("GNU LilyPond 2.24") == LilyPondVersion(2, 24, 0))
        #expect(LilyPondLocator.parseVersion("lilypond: command not found") == nil)
        #expect(LilyPondVersion(2, 24, 4) < LilyPondVersion(2, 26, 0))
        #expect(LilyPondVersion("2.26.0")?.description == "2.26.0")
        #expect(LilyPondVersion("2") == nil && LilyPondVersion("2.x.1") == nil)
    }

    @Test func searchOrder() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["lilypond-2.24.4", "lilypond-2.26.0", "other"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        let dirs = LilyPondLocator.searchDirectories(home: home).map(\.path)
        #expect(Array(dirs.prefix(5)) == [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/lilypond/bin",
            "/Applications/LilyPond.app/Contents/Resources/bin",
        ])
        #expect(Array(dirs.suffix(3)) == [
            home.appendingPathComponent("bin").path,
            home.appendingPathComponent("lilypond-2.26.0/bin").path,
            home.appendingPathComponent("lilypond-2.24.4/bin").path,
        ])
    }

    @Test func userSettingComesFirstAndMayBeADirectory() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

        let fromDir = LilyPondLocator.candidates(userSetting: custom.path, home: home)
        #expect(fromDir.first?.path == custom.appendingPathComponent("lilypond").path)
        let fromFile = LilyPondLocator.candidates(userSetting: "/some/where/lilypond", home: home)
        #expect(fromFile.first?.path == "/some/where/lilypond")
        #expect(LilyPondLocator.candidates(userSetting: "  ", home: home).first?.path == "/opt/homebrew/bin/lilypond")
        // A pasted path may carry a trailing newline.
        let pasted = LilyPondLocator.candidates(userSetting: custom.path + "\n", home: home)
        #expect(pasted.first?.path == custom.appendingPathComponent("lilypond").path)
    }

    @Test func locatesExecutableInHome() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = home.appendingPathComponent("lilypond-2.26.0/bin/lilypond")
        try makeExecutable(exe, contents: machOHeader(cpu: 0x0100_000C))
        // A non-executable file in an earlier directory is skipped.
        let notExecutable = home.appendingPathComponent("bin/lilypond")
        try FileManager.default.createDirectory(at: notExecutable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: notExecutable)

        let found = LilyPondLocator.locate(userSetting: nil, home: home)
        // A real installation in /opt/homebrew or /usr/local wins on a dev machine.
        if let found, !found.path.hasPrefix(home.path) {
            return
        }
        #expect(found?.path == exe.path)
    }

    @Test func machOHeaders() {
        #expect(LilyPondLocator.machOArchitectures(header: machOHeader(cpu: 0x0100_000C)) == [.arm64])
        #expect(LilyPondLocator.machOArchitectures(header: machOHeader(cpu: 0x0100_0007)) == [.x86_64])
        #expect(LilyPondLocator.machOArchitectures(header: fatHeader(cpus: [0x0100_0007, 0x0100_000C]))
                == [.x86_64, .arm64])
        #expect(LilyPondLocator.machOArchitectures(header: Data("#!/bin/sh\n".utf8)) == [])
        #expect(LilyPondLocator.machOArchitectures(header: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52])) == [],
                "Java class file")
        #expect(LilyPondLocator.machOArchitectures(header: Data([0xCF])) == [])
    }

    @Test func architecturesResolveSymlinks() throws {
        // Homebrew layout: bin/lilypond -> ../Cellar/lilypond/2.26.0/bin/lilypond
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Cellar/lilypond/2.26.0/bin/lilypond")
        try makeExecutable(real, contents: machOHeader(cpu: 0x0100_000C))
        let link = root.appendingPathComponent("bin/lilypond")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "../Cellar/lilypond/2.26.0/bin/lilypond")
        #expect(LilyPondLocator.architectures(of: link) == [.arm64])
        #expect(LilyPondLocator.architectures(of: root.appendingPathComponent("missing")) == [])
    }

    @Test func runsVersion() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("lilypond")
        try makeExecutable(script, contents: Data("#!/bin/sh\necho 'GNU LilyPond 2.26.0 (running Guile 3.0)'\n".utf8))
        #expect(LilyPondLocator.version(of: script) == LilyPondVersion(2, 26, 0))
        #expect(LilyPondLocator.version(of: dir.appendingPathComponent("nope")) == nil)
    }
}
