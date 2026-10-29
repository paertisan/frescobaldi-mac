import AppKit
import FrescobaldiCore

/// Uniform type identifiers declared in Info.plist.
enum LilyPondType {
    static let source = "org.lilypond.lilypond-source"
    static let include = "org.lilypond.lilypond-include"
    static let plainText = "public.plain-text"
    static let all = [source, include, plainText]
}

/// The document class for every window. The text lives in `textStorage`,
/// which the editor's layout manager shares.
@objc(LilyPondDocument)
final class LilyPondDocument: NSDocument {
    let textStorage = NSTextStorage()

    /// Set while the document replaces its own text (load, revert), so the
    /// editor can skip auto-indent and similar edit hooks.
    private(set) var isLoading = false

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { LilyPondType.all }
    override class var writableTypes: [String] { LilyPondType.all }
    override class func isNativeType(_ type: String) -> Bool { LilyPondType.all.contains(type) }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [fileType ?? LilyPondType.source]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        switch typeName {
        case LilyPondType.include: "ily"
        case LilyPondType.plainText: fileURL?.pathExtension.isEmpty == false ? fileURL?.pathExtension : "ly"
        default: "ly"
        }
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    var text: String { textStorage.string }

    /// Replaces the whole text without undo (used for loading and templates).
    func setText(_ string: String) {
        isLoading = true
        defer { isLoading = false }
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: string)
        textStorage.setAttributes(EditorStyle.baseAttributes,
                                  range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // LilyPond source is UTF-8; fall back to Latin-1 for old files.
        let string = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        // read(from:) runs on the main thread unless canConcurrentlyReadDocuments
        // says otherwise (it doesn't), so touching textStorage is fine.
        setText(string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(textStorage.string.utf8)
    }

    // MARK: Engrave on save

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            // Read the flag first: the engraver's completion handler clears it.
            let forEngrave = self?.isSavingForEngrave ?? false
            completionHandler(error)
            guard error == nil, let self, !forEngrave,
                  saveOperation == .saveOperation || saveOperation == .saveAsOperation,
                  Preferences.engraveOnSave else { return }
            for case let controller as DocumentWindowController in self.windowControllers {
                controller.engrave(mode: .preview, saveFirst: false)
            }
        }
    }

    /// True while the engraver saves the document itself.
    var isSavingForEngrave = false

    // MARK: Printing prints the PDF preview

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let controller = windowControllers.first as? DocumentWindowController,
              let operation = controller.previewPrintOperation(printInfo: printInfo) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
                NSLocalizedDescriptionKey: "Engrave the document before printing.",
            ])
        }
        return operation
    }
}

/// Fonts and base attributes for the editor.
enum EditorStyle {
    static var font: NSFont { Preferences.editorFont }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }
}
