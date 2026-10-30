# Checking the app on a Mac

The app sources (`Sources/Frescobaldi`) were written on Linux. They were
first built and run on a Mac on 2026-10-29: M1 Max, macOS 27, Xcode 27.1
(Swift 6.4), LilyPond 2.26.0 arm64 from Homebrew. This file records what
was checked then; re-run it after larger changes.

Expected setup: Apple silicon Mac, macOS 26 or later, Xcode at
`/Applications/Xcode.app`, LilyPond at `/opt/homebrew/bin/lilypond`.

## 1. Build

```bash
cd FrescobaldiMac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OPEN=1 scripts/build-app.sh             # also fetches python-ly into build/python
PYTHON_LY_DIR=build/python swift test   # 68 tests, python-ly ones included
```

The app compiled on the first try. None of the expected problems below
came up; the only diagnostic was a warning about a weak capture inside a
strong one in `DocumentWindowController.runLyEdit`, now fixed.

- [x] Concurrency diagnostics: none (Swift 5 language mode).
- [x] `LilyPondDocument.save(to:ofType:for:completionHandler:)` override
      matches the SDK.
- [x] `presentError(_:)` unused results: no warnings.
- [x] `LilyPondDocument.read(from:ofType:)` / `data(ofType:)`: no warnings.
- [x] SwiftUI `List(selection:)` in `OutlineSidebar.swift` and
      `glassEffect(.regular, in: Capsule())` in `PreviewViewController.swift`
      compile; the preview controls use Liquid Glass on macOS 27.

## 2. Run through the features

Checked by hand with a two-staff minuet (with an `\include`), a file with
errors and a warning, a long score, and the templates. Light mode was
checked by launching with `--args -NSRequiresAquaSystemAppearance YES`.

- [x] Launch: an untitled window opens with sidebar | editor | preview, a
      unified toolbar, and "Ready to engrave" centered in it.
      *Was broken:* the window shrank to 172 pt tall (fixed).
- [x] Open a `.ly` file: syntax colors look right in light and dark mode, line
      numbers line up (also with wrapped lines and an empty last line).
      *Was broken:* the editor text was invisible behind the ruler (fixed).
- [x] Editing: Return auto-indents after `{` or `<<`; typing `}` on a blank
      line outdents; Tab inserts spaces; ⌘/ toggles `%` comments; ⌘] / ⌘[
      shift lines; ⌘L goes to a line; ⌥⌘= / ⌥⌘- change the font size.
      Smart quotes and spell checking are off. Undo works for each of these.
      (⌘/ was checked from the Format menu: the test tool sends ⌘/ with an
      empty character string, which no app can match.)
- [x] Find bar: ⌘F, ⌥⌘F (replace), ⌘G / ⇧⌘G, ⌘E.
- [x] Opening a document shows the PDF from an earlier run, and enables
      Play for its MIDI, if they're at least as new as the source. A stale
      PDF isn't shown.
- [x] ⌘R engraves: an edited titled document is saved first (the edited dot
      goes away), the status shows progress and then "Engraved in x s", and the
      PDF appears. Engrave again: the page and zoom stay put.
- [x] Untitled document: ⌘R engraves a temporary copy; point-and-click still
      jumps into the untitled editor.
- [x] An error in the source: the Issues panel opens, the ruler shows a red
      dot, clicking an issue selects the spot, and ⌘' / ⇧⌘' step through
      issues. ⇧⌘' works as is.
      *Was poor:* the panel opened at its 90 pt minimum, showing one issue
      (now about a third of the editor height).
- [x] ⇧⌘R engraves without point-and-click links (no `textedit` in the
      PDF); ⌘. stops a long engrave ("Stopped", no lilypond left running).
- [x] Click a note in the PDF: the editor selects the note.
      *Was broken:* PDFKit on macOS 27 never calls
      `pdfViewWillClick(onLink:with:)` for LilyPond's links. `ScoreView`
      now handles the click itself.
- [x] Move the cursor onto a note: the note gets a tinted box in the PDF and
      the preview scrolls to it if needed.
- [x] A score with `\midi { }`: Play (⌥⌘P) plays through the built-in GM sound
      bank; the toolbar button turns into Stop, and back to Play at the end.
- [x] Tools > Transpose (⌃⌘T) with and without a selection, Translate Pitch
      Names, Relative ↔ Absolute, Simplify Accidentals, Re-indent, Reformat.
      Each is one Undo step. (Running two tools back to back: the second
      result is dropped with a beep because the text changed. As designed.)
- [x] File > New from Template: three templates; the cursor lands at `$CURSOR`
      and `\version` shows the installed LilyPond version.
- [x] Settings (⌘,): General shows "LilyPond 2.26.0" with an "Apple silicon"
      badge; choosing another path re-detects it. "Engrave when saving" works
      with ⌘S. Editor settings apply right away.
- [x] Window tabs (Window > Merge All Windows), Versions (File > Revert To >
      Browse All Versions), Rename/Move (File > Rename… shows the title-bar
      popover).
- [ ] Clicking the title in the title bar, and the proxy icon on hover:
      neither appeared in testing. Check by hand with a real mouse.
- [x] File > Show PDF in Finder, Print (prints the PDF).
- [ ] File > Export PDF: the save sheet opens with the PDF's name, but the
      test tool can't confirm save sheets, so the copy itself is untested.
- [x] View: toggling the sidebar, issues panel and preview; Zoom In/Out/Fit
      Width; the floating page/zoom controls (Liquid Glass on macOS 26).

## 3. Things to look at closely

- **Line-number ruler with `fullSizeContentView`.** It did draw over the
  text: its dirty rect reached past its bounds. The ruler now sets
  `clipsToBounds` and fills only its bounds.
- **PDF position after reload** uses `currentDestination`. No drift: after
  re-engraving at 154%, every link was at the same spot.
- **Point-and-click paths.** The test scores lived under `/private/tmp`, and
  both titled and untitled documents matched LilyPond's paths.
- **Large files.** Not measured yet. The line index is rebuilt on every
  keystroke (a linear scan).

## 4. Also noticed

- On macOS 27 an untitled document can get a system-suggested name
  ("Frescobaldi Score — Suggested"). The temporary copy for engraving is
  named after it, which is harmless.
- Opening a file doesn't replace the empty Untitled window from launch.
