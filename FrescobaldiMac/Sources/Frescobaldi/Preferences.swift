import AppKit
import FrescobaldiCore

/// UserDefaults keys and typed accessors. SwiftUI settings use the same keys
/// with @AppStorage.
enum Preferences {
    enum Key {
        static let lilypondPath = "lilypondPath"
        static let engraveOnSave = "engraveOnSave"
        static let editorFontSize = "editorFontSize"
        static let indentWidth = "indentWidth"
        static let showLineNumbers = "showLineNumbers"
        static let claudeAccess = "claudeAccess"
        static let editorFontName = "editorFontName"
        static let editorTheme = "editorTheme"
    }

    /// Cascadia Code if it's installed (it has coding ligatures; Cascadia Mono
    /// doesn't), otherwise the system's monospaced font.
    static let defaultFontName = "Cascadia Code"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.lilypondPath: "",
            Key.engraveOnSave: false,
            Key.editorFontSize: 13.0,
            Key.indentWidth: 2,
            Key.showLineNumbers: true,
            Key.claudeAccess: true,
            Key.editorFontName: defaultFontName,
            Key.editorTheme: EditorTheme.Name.monokai.rawValue,
        ])
    }

    static var lilypondPath: String { UserDefaults.standard.string(forKey: Key.lilypondPath) ?? "" }
    static var engraveOnSave: Bool { UserDefaults.standard.bool(forKey: Key.engraveOnSave) }
    static var indentWidth: Int { max(1, min(8, UserDefaults.standard.integer(forKey: Key.indentWidth))) }
    static var showLineNumbers: Bool { UserDefaults.standard.bool(forKey: Key.showLineNumbers) }
    /// Let frescobaldi-mcp (Claude) read and edit open documents.
    static var claudeAccess: Bool { UserDefaults.standard.bool(forKey: Key.claudeAccess) }

    static var editorTheme: EditorTheme.Name {
        EditorTheme.Name(rawValue: UserDefaults.standard.string(forKey: Key.editorTheme) ?? "") ?? .monokai
    }

    /// The editor font family ("" = the system's monospaced font).
    static var editorFontName: String { UserDefaults.standard.string(forKey: Key.editorFontName) ?? "" }

    static var editorFont: NSFont {
        let stored = UserDefaults.standard.double(forKey: Key.editorFontSize)
        let size = CGFloat(stored > 4 ? stored : 13)
        let family = editorFontName
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch font families, for the font setting.
    static func monospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."),
                  let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
            else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    }

    /// The LilyPond executable from the setting or the standard locations.
    static func lilypond() -> URL? {
        LilyPondLocator.locate(userSetting: lilypondPath)
    }

    static let didChange = Notification.Name("FrescobaldiPreferencesDidChange")
}

/// Where the bundled resources are. In the app bundle they're in
/// Contents/Resources; with `swift run` they're found next to the package.
enum AppResources {
    static var root: URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("Templates").path) {
            return resources
        }
        // Development: .build/<config>/Frescobaldi → package root/Resources
        var url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Resources")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Templates").path) {
                return candidate
            }
        }
        return Bundle.main.bundleURL
    }

    static var templates: URL { root.appendingPathComponent("Templates", isDirectory: true) }

    /// python-ly and the driver script.
    static var pythonLyTool: PythonLyTool? {
        guard let python = PythonLyTool.findPython() else { return nil }
        let bundled = root.appendingPathComponent("python", isDirectory: true)
        let driver = bundled.appendingPathComponent("fmac_lytool.py")
        var lyDir = bundled
        if !FileManager.default.fileExists(atPath: lyDir.appendingPathComponent("ly/__init__.py").path) {
            // Development: python-ly downloaded by scripts/build-app.sh, or $PYTHON_LY_DIR.
            if let env = ProcessInfo.processInfo.environment["PYTHON_LY_DIR"] {
                lyDir = URL(fileURLWithPath: env)
            } else {
                lyDir = root.deletingLastPathComponent().appendingPathComponent("build/python")
            }
        }
        guard FileManager.default.fileExists(atPath: driver.path),
              FileManager.default.fileExists(atPath: lyDir.appendingPathComponent("ly/__init__.py").path) else {
            return nil
        }
        return PythonLyTool(pythonLyDirectory: lyDir, driverScript: driver, python: python)
    }

    /// The General MIDI sound bank that ships with macOS.
    static let soundBank = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
}
