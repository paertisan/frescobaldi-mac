import AppKit

// The first NSDocumentController created becomes the shared one, so make
// ours before anything else touches NSDocumentController.shared.
_ = DocumentController()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
