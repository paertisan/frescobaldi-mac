# Frescobaldi for macOS (Swift)

A native macOS front end for LilyPond, forked from
[Frescobaldi 4.0.7](https://github.com/frescobaldi/frescobaldi/releases/tag/v4.0.7).
The original PyQt6 app stays in `../frescobaldi/` as the reference
implementation; this folder replaces its UI with Swift, AppKit and SwiftUI.

**Status:** early scaffold. The package manifest and ported templates exist.
The sources below are the plan and haven't been written yet.

## Why Swift instead of the Qt app

- The Qt UI is dated on macOS: Tango icons, no dark mode, a hand-built
  `[modified]` title, no proxy icon, and Ctrl+M (engrave) colliding with ⌘M.
- Stock 4.0.7 also crashes on macOS 26+ with Qt ≥ 6.10.
  `QAppleIconEngine` traps when an SF Symbol is drawn at a degenerate size
  (upstream issue #2160, still present in Qt 6.12). Upstream pins Qt 6.9 on
  macOS as a workaround.
- Most of Frescobaldi's LilyPond intelligence lives in
  [python-ly](https://github.com/frescobaldi/python-ly), not in the Qt app.
  We reuse that engine instead of rewriting it.

## Architecture

| Area | Approach |
|---|---|
| App lifecycle | AppKit (`main.swift` + `AppDelegate`), programmatic main menu, NSDocument architecture |
| Document | `@objc(LilyPondDocument) NSDocument` owning an `NSTextStorage`; `autosavesInPlace = true` (Versions, Revert To, rename/move in the title bar, proxy icon, edited dot, window tabs) |
| Window | `NSSplitViewController`: sidebar (outline) · editor + collapsible log (nested vertical split) · PDF preview. `fullSizeContentView`, unified `NSToolbar` with SF Symbols, centered engrave-status item (SwiftUI in `NSHostingView`) |
| Editor | `NSTextView` on TextKit 1 (`usingTextLayoutManager: false`), SF Mono, line-number `NSRulerView` with error/warning markers, auto-indent, 2-space indent, toggle comment (⌘/), shift left/right (⌘[ ⌘]), go to line (⌘L), find bar |
| Highlighting | Swift lexer in `FrescobaldiCore` (resumable state, UTF-16 `NSRange` tokens). Colors are applied as `NSLayoutManager` temporary attributes on the visible range only, with lexer-state checkpoints. Colors use system `NSColor`s so dark mode and Increase Contrast work automatically |
| Engraving | `Process` running `lilypond -dpoint-and-click --pdf -o <dir/base> <abs path>`. `LANG=en_US.UTF-8` keeps messages parseable; PATH is extended with `/opt/homebrew/bin:/usr/local/bin`. Titled documents are saved first; untitled ones are written to a temp dir. Outputs come from log lines ``Converting to `x.pdf'...`` and ``MIDI output to `x.midi'...``. ⌘R preview, ⇧⌘R publish (`-dno-point-and-click`), ⌘. stop. Optional engrave on save |
| Preview | PDFKit `PDFView` that reloads while keeping page and zoom. Clicking a `textedit://` link jumps the editor (`showFindIndicator`). Moving the editor cursor highlights the matching notes in the PDF via a link index. Floating zoom/page controls use `.glassEffect()` on macOS 26 with a material fallback. Empty state uses `ContentUnavailableView` |
| Issues/log | SwiftUI panel: Issues list (click to jump; opens included files if needed) plus raw log |
| Tools | python-ly CLI (`python3 -I -c "import sys; sys.path.insert(0, R); from ly.cli.main import main; sys.exit(main())" <cmd>`), with stdin as the selection or whole document. Commands: transpose, translate pitch names, rel2abs/abs2rel, simplify accidentals, indent, reformat. Edits are undoable. python-ly 0.9.10 (pure Python, needs ≥3.8) is bundled in `Contents/Resources/python` |
| MIDI | `AVMIDIPlayer` with `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls` |
| Settings | `NSTabViewController` (toolbar tab style) hosting SwiftUI forms. Includes the LilyPond path with auto-detect, version, and an **arm64 / Intel (Rosetta)** badge from the Mach-O header |
| Templates | `Resources/Templates/*.ly`, ported from Frescobaldi's built-ins (`$LILYPOND_VERSION`, `$CURSOR` placeholders) |

LilyPond search order: user setting, `/opt/homebrew/bin`, `/usr/local/bin`,
`/opt/local/bin`, `/opt/lilypond/bin`,
`/Applications/LilyPond.app/Contents/Resources/bin`, `~/bin`,
`~/lilypond-*/bin`.

Shortcuts follow macOS conventions. Ctrl+Cmd+F for full screen and the
Window-menu tab commands come from AppKit automatically.

## Verified facts (LilyPond 2.26.0, macOS 27)

- PDFKit exposes LilyPond links as `PDFAnnotation.url`, in the form
  `textedit:///abs/path.ly:LINE:START:END`. LINE is 1-based; START/END are
  0-based character columns of the note.
- Log messages look like `file:LINE:COL: error|warning: text`, where COL is
  **1-based**. The two following lines show the source split at the error.
  `fatal error: failed files: …` is a summary and can be skipped.
- A PDF is still produced when there are errors.
- `python3 -m ly "transpose c d"` and `ly "translate english"` read stdin and
  write stdout. Languages: nederlands, catalan, deutsch, english, espanol,
  italiano, norsk, portugues, suomi, svenska, vlaams.

## Building

Requires Xcode 27+ (the macOS 26+ SDK gives the Liquid Glass look). The build
targets arm64 only; deployment target is macOS 14.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-app.sh   # → build/Frescobaldi.app
```

`scripts/build-app.sh` (to do) will:
- `swift build -c release --arch arm64`
- assemble `Frescobaldi.app` with an Info.plist declaring:
  - bundle id `io.github.paertisan.frescobaldi`
  - imported UTIs `org.lilypond.lilypond-source` (.ly) and
    `org.lilypond.lilypond-include` (.ily, .lyi), plus a `public.plain-text`
    alternate type, with `NSDocumentClass` = `LilyPondDocument`
- copy `../frescobaldi/icons/org.frescobaldi.Frescobaldi.icns`, the templates
  and python-ly into the bundle
- ad-hoc codesign the bundle

SPM resource bundles aren't used, because they break app-bundle signing.

## Roadmap after the MVP

Score Wizard, snippets/quick insert, bracket matching, document-wide
transpose with context, MusicXML import (`musicxml2ly`), multiple-PDF picker,
dark "paper" option, notarized DMG.

## License

GPL-2.0-or-later, same as Frescobaldi and python-ly.
