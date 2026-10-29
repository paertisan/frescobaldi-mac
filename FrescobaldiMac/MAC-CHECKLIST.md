# Checking the app on a Mac

The app sources (`Sources/Frescobaldi`) were written on Linux, where AppKit,
PDFKit and SwiftUI aren't available. They pass a syntax check but have never
been type-checked or run. `FrescobaldiCore` and its 67 tests do build and
pass (Swift 6.2.4 on Linux).

Expected setup: Apple silicon Mac, macOS 26 or later, Xcode at
`/Applications/Xcode.app`, LilyPond at `/opt/homebrew/bin/lilypond`.

## 1. Build

```bash
cd FrescobaldiMac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PYTHON_LY_DIR=build/python swift test   # after build-app.sh has fetched python-ly
OPEN=1 scripts/build-app.sh
```

Likely compile problems, in rough order of likelihood:

- [ ] **Concurrency diagnostics.** The package uses Swift 5 language mode, so
      most actor-isolation problems should only be warnings. If any are errors,
      the usual fix is `MainActor.assumeIsolated { … }` in notification and
      `DispatchQueue.main` callbacks.
- [ ] **`LilyPondDocument.save(to:ofType:for:completionHandler:)` override.**
      Newer SDKs may mark the completion handler `@Sendable`; if the override
      doesn't match, copy the signature Xcode suggests.
- [ ] `presentError(_:)` returning an unused `Bool`: only warnings.
- [ ] Concurrency warnings in `LilyPondDocument.read(from:ofType:)` /
      `data(ofType:)` if the SDK makes them nonisolated: wrap the bodies in
      `MainActor.assumeIsolated { … }` (safe, since reading isn't concurrent).
- [ ] SwiftUI: `List(selection:)` with `.tag(item.id)` in `OutlineSidebar.swift`;
      `glassEffect(.regular, in: Capsule())` in `PreviewViewController.swift`
      (needs the macOS 26 SDK; it's behind `#available`).

## 2. Run through the features

- [ ] Launch: an untitled window opens with sidebar | editor | preview, a
      unified toolbar, and "Ready to engrave" centered in it.
- [ ] Open a `.ly` file: syntax colors look right in light and dark mode, line
      numbers line up (also with wrapped lines and an empty last line).
- [ ] Editing: Return auto-indents after `{` or `<<`; typing `}` on a blank
      line outdents; Tab inserts spaces; ⌘/ toggles `%` comments; ⌘] / ⌘[
      shift lines; ⌘L goes to a line; ⌥⌘= / ⌥⌘- change the font size.
      Smart quotes and spell checking are off. Undo works for each of these.
- [ ] Find bar: ⌘F, ⌥⌘F (replace), ⌘G / ⇧⌘G, ⌘E.
- [ ] ⌘R engraves: an edited titled document is saved first (the edited dot
      goes away), the status shows progress and then "Engraved in x s", and the
      PDF appears. Engrave again: the page and zoom stay put.
- [ ] Untitled document: ⌘R engraves a temporary copy; point-and-click still
      jumps into the untitled editor.
- [ ] An error in the source: the Issues panel opens, the ruler shows a red
      dot, clicking an issue selects the spot, and ⌘' / ⇧⌘' step through issues. (If ⇧⌘' doesn't fire, change its key
      equivalent in `MainMenu.swift` to `"\""` with only `.command`.)
- [ ] ⇧⌘R engraves without point-and-click links; ⌘. stops a long engrave.
- [ ] Click a note in the PDF: the editor selects the note.
      **Unverified:** that `PDFViewDelegate.pdfViewWillClick(onLink:with:)` is
      called for LilyPond's link annotations.
- [ ] Move the cursor onto a note: the note gets a tinted box in the PDF and
      the preview scrolls to it if needed.
- [ ] A score with `\midi { }`: Play (⌥⌘P) plays through the built-in GM sound
      bank; the toolbar button turns into Stop.
- [ ] Tools > Transpose (⌃⌘T) with and without a selection, Translate Pitch
      Names, Relative ↔ Absolute, Simplify Accidentals, Re-indent, Reformat.
      Each is one Undo step.
- [ ] File > New from Template: three templates; the cursor lands at `$CURSOR`
      and `\version` shows the installed LilyPond version.
- [ ] Settings (⌘,): General shows "LilyPond 2.26.0" with an "Apple silicon"
      badge; choosing another path re-detects it. "Engrave when saving" works
      with ⌘S. Editor settings apply right away.
- [ ] Window tabs (Window > Merge All Windows), Versions (File > Revert To >
      Browse All Versions), Rename/Move from the title bar, proxy icon.
- [ ] File > Export PDF, Show PDF in Finder, Print (prints the PDF).
- [ ] View: toggling the sidebar, issues panel and preview; Zoom In/Out/Fit
      Width; the floating page/zoom controls (Liquid Glass on macOS 26).

## 3. Things to look at closely

- **Line-number ruler with `fullSizeContentView`.** macOS 14 changed view
  clipping defaults, and rulers have been known to draw over text. If they
  do, look at `LineNumberRuler.draw(_:)` and the scroll view's
  `contentView` clipping.
- **PDF position after reload** uses `currentDestination`; check that it
  doesn't drift by a line each time.
- **Point-and-click paths.** LilyPond may print a path that differs from the
  document URL (`/private/var` vs `/var` for temp files). Paths are compared
  after `resolvingSymlinksInPath()`, which should cover this.
- **Large files.** The line index is rebuilt on every keystroke (a linear
  scan). That should be fine up to a few hundred thousand characters.
