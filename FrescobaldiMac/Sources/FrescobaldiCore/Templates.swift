import Foundation

/// A new-document template (`Resources/Templates/*.ly`).
///
/// Templates use Frescobaldi's placeholders: `$LILYPOND_VERSION` becomes the
/// installed LilyPond version and `$CURSOR` marks where the insertion point goes.
public struct LilyPondTemplate: Equatable, Sendable {
    public var name: String
    public var url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// The `.ly` files in `directory`, sorted by name.
    public static func templates(in directory: URL) -> [LilyPondTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "ly" }
            .map { LilyPondTemplate(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func render(version: LilyPondVersion?) throws -> (text: String, cursor: Int) {
        try Self.render(String(contentsOf: url, encoding: .utf8), version: version)
    }

    /// Substitutes the placeholders. `cursor` is the UTF-16 offset of the
    /// first `$CURSOR` (or 0); every `$CURSOR` is removed.
    public static func render(_ template: String, version: LilyPondVersion?) -> (text: String, cursor: Int) {
        let versionString = (version ?? LilyPondVersion(2, 24, 0)).description
        var text = template.replacingOccurrences(of: "$LILYPOND_VERSION", with: versionString)
        let marker = "$CURSOR"
        let ns = text as NSString
        let first = ns.range(of: marker)
        let cursor = first.location == NSNotFound ? 0 : first.location
        text = text.replacingOccurrences(of: marker, with: "")
        return (text, cursor)
    }
}

/// Finds point-and-click links (from the PDF) for an editor position.
public struct PointAndClickIndex<Item> {
    public struct Entry {
        public var link: TextEditLink
        public var item: Item
    }

    private var byLine: [Int: [Entry]] = [:]

    public init() {}

    public init(_ entries: [(TextEditLink, Item)]) {
        for (link, item) in entries { add(link, item) }
    }

    public var isEmpty: Bool { byLine.isEmpty }

    public mutating func add(_ link: TextEditLink, _ item: Item) {
        byLine[link.line, default: []].append(Entry(link: link, item: item))
    }

    /// Items whose link covers `column` on `line` of `path`. When none covers
    /// it, the items starting nearest after the column (the next note).
    /// Paths are compared after resolving symlinks and `..`.
    public func items(path: String, line: Int, column: Int) -> [Item] {
        let target = Self.normalize(path)
        let onLine = (byLine[line] ?? []).filter { Self.normalize($0.link.path) == target }
        let covering = onLine.filter { $0.link.startColumn <= column && column <= $0.link.endColumn }
        if !covering.isEmpty { return covering.map(\.item) }
        let after = onLine.filter { $0.link.startColumn > column }
        guard let nearest = after.map(\.link.startColumn).min() else { return [] }
        return after.filter { $0.link.startColumn == nearest }.map(\.item)
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
