import AppKit
import FrescobaldiCore

/// Maps every file to LilyPondDocument, also when running without an
/// Info.plist (`swift run`), and creates documents from templates.
final class DocumentController: NSDocumentController {
    override var documentClassNames: [String] { ["LilyPondDocument"] }
    override var defaultType: String? { LilyPondType.source }

    override func documentClass(forType typeName: String) -> AnyClass? {
        LilyPondDocument.self
    }

    override func typeForContents(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "ly": return LilyPondType.source
        case "ily", "lyi": return LilyPondType.include
        default:
            if let type = try? super.typeForContents(of: url), LilyPondType.all.contains(type) { return type }
            return LilyPondType.plainText
        }
    }

    /// File > New from Template.
    func newDocument(from template: LilyPondTemplate) {
        do {
            let rendered = try template.render(version: AppDelegate.shared.lilypondVersion)
            guard let document = try openUntitledDocumentAndDisplay(false) as? LilyPondDocument else { return }
            document.setText(rendered.text)
            document.updateChangeCount(.changeDone)
            document.makeWindowControllers()
            document.showWindows()
            if let controller = document.windowControllers.first as? DocumentWindowController {
                controller.editor.select(NSRange(location: rendered.cursor, length: 0))
            }
        } catch {
            presentError(error)
        }
    }
}
