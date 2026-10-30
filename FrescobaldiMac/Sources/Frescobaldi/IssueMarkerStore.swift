import Foundation
import FrescobaldiCore

/// The gutter markers of every file, from the last engrave that read it, so
/// a window for an included file shows that file's errors and a clean
/// engrave clears them in every window (upstream #1441).
@MainActor
final class IssueMarkerStore {
    static let shared = IssueMarkerStore()

    /// Posted when markers change; `paths` (a `Set<String>` of
    /// `IssueMarkers.key`s) says whose.
    static let didChange = Notification.Name("IssueMarkerStoreDidChange")
    /// Posted when a file was edited; `path` and `edit` (a `LineEdit`), so
    /// windows can move their messages for that file.
    static let didEdit = Notification.Name("IssueMarkerStoreDidEdit")

    private(set) var markers = IssueMarkers()

    func lines(for path: String) -> IssueMarkers.Lines { markers.lines(for: path) }

    /// After a run that read the files at `paths`.
    func update(with messages: [LilyPondMessage], covering paths: Set<String>) {
        let changed = markers.update(with: messages, covering: paths)
        if !changed.isEmpty {
            NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["paths": changed])
        }
    }

    /// The file at `path` was edited: its markers and messages move with the text.
    func edited(_ path: String, _ edit: LineEdit) {
        guard !edit.isIdentity else { return }
        if markers.apply(edit, to: path) {
            NotificationCenter.default.post(name: Self.didChange, object: self,
                                            userInfo: ["paths": Set([IssueMarkers.key(path)])])
        }
        NotificationCenter.default.post(name: Self.didEdit, object: self, userInfo: ["path": path, "edit": edit])
    }
}
