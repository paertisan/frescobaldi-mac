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
PYTHON_LY_DIR=build/python swift test   # 148 core + 14 MCP tests, python-ly and LilyPond ones included
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

## 2b. Claude (MCP)

Checked by driving `Contents/Helpers/frescobaldi-mcp` over stdio with a
small MCP client (initialize, tools/list, tools/call), with the app running.

- [x] `initialize` negotiates the protocol version; `tools/list` lists 11
      tools; unknown methods and tools get JSON-RPC errors.
- [x] `engrave` on text and files returns issues with line and column;
      `transform`, `outline`, `templates`, `lilypond_info` work without the app.
- [x] `render_page` returns a legible PNG (a one-page minuet: 900×489 px
      after trimming instead of 900×1273).
- [x] With the app: `list_documents`, `get_document` (selection and cursor),
      `edit_document` (one "Undo Claude Edit" step; ambiguous `old_text` is
      refused), `transform` on a document, `engrave_document` right after an
      edit (the document is saved first), `reveal`, clear errors for unknown
      documents and lines.
- [x] Settings > Claude: the switch removes and recreates the socket; the
      helper then says access is off. Copy buttons show the helper's path.
- [ ] A real Claude Code or Claude Desktop session using the server (no
      macOS `claude` CLI on the test machine).

## 2c. Themes and projects

Checked with the Mahler 9 example project (22 include files, a style
sheet with absolute includes of a music font) and generated projects.

- [x] Font: Cascadia Code by default (resolves to CascadiaCode-Regular);
      the font menu lists the installed monospaced families.
- [x] Themes in both appearances, by launching with
      `--args -NSRequiresAquaSystemAppearance YES` for light mode:
      Everforest Light/Dark (defaults), a Rainglow light/dark pair, a dark
      theme in light mode and a light theme in dark mode (the window takes
      the theme's appearance), and System in both modes.
- [x] The whole window follows the theme: toolbar area, sidebar, issues
      panel, around the PDF. The editor stays below the toolbar (was broken
      with the transparent titlebar after leaving full screen).
- [x] Theme browser: search, Light/Dark/All filter, previews; picking a
      theme applies it at once.
- [ ] Switching the system between light and dark mode while the app runs
      (handled via `NSApp.effectiveAppearance`; not switched in testing).
- [x] Project sidebar on the Mahler project: main file from the master
      variable, include tree, folder, suggestions for the two absolute
      includes only; clicking a suggestion opens the file as a tab at the
      line.
- [x] ⌘R in `notes/floeten.ily` engraves `mahler9-I-p1-2.ly` ("Engraved
      mahler9-I-p1-2.ly in 8.6 s"); the existing PDF shows on open.
- New Project became New Score: see 2f.

## 2d. Targets, project settings and build commands

Checked with a generated chamber-orchestra project (a score and 12 parts)
in dark and light mode, and the Mahler project (read only).

- [x] Targets: the score and the 12 parts (grouped under a collapsed
      `parts` folder in the sidebar); the Mahler project has one,
      `mahler9-I-p1-2.ly`. The toolbar shows the current file's target
      (`spring-serenade.ly` from `music/flute.ily`).
- [x] ⌘R from `music/flute.ily` engraves the score; Engrave All Targets
      engraves 13 files in 4.8 s ("Engraving 13 targets (n done)…") and
      keeps the score in the preview; the sidebar's ▶ engraves one part.
- [x] An include file nothing uses: "No Target" in the toolbar, a
      suggestion in the sidebar, and ⌘R explains instead of engraving,
      with a button that engraves the main score.
- [x] Project Settings…: the sheet in dark mode; setting an output folder
      and a command writes only those two keys to `frescobaldi.json`; the
      score then engraves into `build/` with point-and-click links.
- [x] A build command (`make parts`, whose Makefile runs LilyPond inside
      `parts/` with `-o ../build`): its two errors land on the right line
      of `music/flute.ily` with markers. Apple's make doesn't print which
      folder it enters, so the PDF is found by name among the files the
      command wrote.
- [x] A command added to `frescobaldi.json` by hand asks first, showing
      the command and its folder; it runs after Run, and Cancel is the
      default button.
- [ ] The toolbar target menu opened by hand: the automation tool can't
      open pop-up menus in the background, so its look and choosing in it
      are unchecked (its title follows the choice and the current file).

## 2e. Fixes from the upstream issue review

Bugs Frescobaldi has upstream that this app shared, checked in dark and
light mode with a score whose `\include "part.ily"` has an error.

- [x] `#(set-default-paper-size "bogus")`: "Unknown paper size: bogus" is
      in the Issues list ("No location · Show in Log"; a click opens the
      Log) and counts in the toolbar badge.
- [x] Engraving the score marks line 3 of `part.ily` in that file's own
      window. Inserting two lines above moves the marker to line 5, and
      the score window's issues say `part.ily:5`. After fixing the error,
      a clean engrave of the score clears the marker.
- [x] A file whose `\book` has `\bookOutputSuffix "parts"` shows
      `name-parts.pdf` when opened.
- [x] Export PDF after ⌘R: the saved PDF has no `textedit:` links (the
      preview's has 9 and keeps them); the status shows "Engraving for
      publishing…" and then the previous result again.
- [x] Tools > Relative to Absolute on music with `\resetRelativeOctave`:
      an alert says why, and the text is unchanged.

Not checked yet (from the same review):

- [ ] Double-click a `.ly` in Finder while the app isn't running: no extra
      Untitled window (upstream #1062).
- [ ] MIDI: a fast run followed by `\tuplet 5/4 { e16 fs gs a b }` leaves
      no notes sounding (upstream #1595).
- [ ] Option-drag for a rectangular selection; Toggle Comment and Shift act
      on each line of it (upstream #1320).

## 2f. New Score wizard

Checked in dark and light mode.

- [x] Tests: every preset and 7 option combinations engrave (score and every
      part) with LilyPond 2.26, no errors or warnings; no project
      suggestions; folders that exist and aren't empty are refused.
- [x] MIDI of a concert-pitch B♭ clarinet playing C sounds C (72); entered
      as written, a written C sounds B♭ (70).
- [x] File > New Score… opens the window; presets fill the players
      (String Quartet: Violin I, Violin II, Viola, Cello); the + menu adds
      a piano by family in score order; renaming a player shows in the
      preview.
- [x] Key, time signature, tempo, metronome mark and empty bars update the
      preview (A♭ major in 6/8 with the clarinet and horn transposed).
- [x] The preview shows the start of the score and the whole page on click;
      it follows each change after about a second for 12 staves.
- [x] Save Ensemble… names a set; it shows under My Ensembles and choosing
      it brings the players back.
- [x] Return finishes a name without going to the next step.
- [x] `new_score` through the bundled helper with the app running: a brass
      quintet in B♭ major, 2/2, opens with the project sidebar (score and
      five parts as targets) and engraves without issues.
- [ ] Create… up to the end: the save panel opens with the title as the
      project name, but the automation tool can't take it to a scratch
      folder, so the files were written through `new_score` instead.
- [ ] Very long player names ("Oboe and English Horn") run past the left
      edge of the page; LilyPond doesn't widen the indent for them.

## 2g. Quieter interface

Checked with the Mahler 9 project (opened only: not engraved or saved;
its files are unchanged) and a scratch score with an error and a warning,
in Charcoal (dark) and Ivory (light).

- [x] Toolbar: Engrave becomes Stop while running; the target menu shows
      the name only; idle status is a faint "⌘R to engrave"; a run ends
      with "Engraved in 0.4 s" or "Engraving failed · 1 error · 1 warning".
- [x] The issues panel starts closed, opens for an error, and closes after
      the fix engraves cleanly; gutter marks go with it.
- [x] Sidebar: Outline/Project as text tabs; Suggestions folded to a count;
      sections fold; target run buttons show on hover; folder icons grey.
- [x] Empty states ("No Preview") with a serif title; no "No Project" flash
      while a saved file's project loads.
- [x] Ivory and Charcoal colors (contrast checked: text 13–17.5:1, comments
      4.6–5.4:1, syntax colors 4.7:1 or more); warm selection.
- [x] The New Score window follows the theme; the segmented steps and the
      selected ensemble use the clay accent (the compiled `Assets.car` has
      #C6613F light, #D97757 dark).
- [ ] Seen once: after opening the New Score window right after launch,
      the Mahler window's project and PDF didn't load until the window
      became key. Not reproduced since.
- [ ] Engrave as a prominent (tinted) toolbar button: macOS 26's
      `NSToolbarItem.style = .prominent` showed no effect on macOS 27, so
      it isn't used.

## 2h. Adjusting objects in the preview

Checked on 2026-11-01 with LilyPond 2.26.0. Screen control was declined
for this session, so the app was driven by the debug build's self-test
(`FMAC_SELFTEST`, see README > Building) instead of the mouse: it runs the
real hit testing, drag loop, edit and engrave with posted mouse events and
saves window snapshots. Run in Ivory (light, `NSRequiresAquaSystemAppearance`)
and Charcoal (dark), on a two-staff piano score with every kind of object
and on a score whose notes are in an `\include`d file.

- [x] Tests: link parsing, every `TweakWriter` case, the settings file only
      in preview mode; engraving with `fmac-edit.ly` links all 11 kinds of
      object with no new warnings, an `extra-offset` drag moves the
      object's rectangle by the dragged points (±0.5 pt) and a second drag
      updates the same tweak, and one tweak of every kind engraves without
      warnings with the values reaching the right objects.
- [x] Layout unchanged: the 58-page Mahler 9/I score (a scratch copy) has
      identical point-and-click rectangles (45,681) and warnings (40) with
      and without the file; 17,641 objects are linked. 103.7 s instead of
      103.1 s to engrave; the PDF is 22.2 MB instead of 14.8 MB.
- [x] The toolbar's Adjust toggle shows selected (clay in Ivory), and the
      status says "Drag to adjust · right-click for options" for 4 s.
- [x] Hover outlines the object in clay; slurs and beams show handles
      instead. Tooltip text "Dynamic · p · line 4".
- [x] Dragging: the object fades in place and a copy follows the pointer;
      a slur handle shows the new curve and control polygon; a beam end
      shows the tilted beam.
- [x] Release writes, as one undoable change ("Undo Adjust Beam"), and
      engraves again: `-\tweak extra-offset #'(5.02 . 3.14)` on an accent,
      `-\tweak DynamicLineSpanner.staff-padding #3.86` on `\p`,
      `-\shape #'((0 . 0) (0 . 0) (0 . 3.76) (0 . 0))` on a slur,
      `\once \offset positions #'(2.51 . 0) Beam` before an automatic beam.
- [x] Right-click menu: "Dragging a dynamic changes" with Offset (ticked),
      X-offset, Y-offset, Padding, Distance from Staff, Outside-Staff
      Padding, and Show in Source.
- [x] With Adjust off the preview behaves as before; ⌥ held turns it on.
- [x] A dynamic in `music.ily`: the file opens as a second tab, takes the
      tweak and is saved and engraved; the score's tab stays selected.
- [x] Bug found and fixed: the engrave right after the edit didn't save
      the file (NSDocument counts the change a moment later), so it
      engraved the old text. It now starts on the next run-loop pass.
- [ ] By hand with a real mouse and keyboard: pressing ⌥, the tooltip
      appearing, the context menu opening, the hand cursors, Shift to keep
      a drag straight, dragging near the edge (no autoscroll yet).
- [ ] Adjust on a large score in the app: the self-test used small ones.

## 2i. Piano tables

Checked on 2026-11-01 with LilyPond 2.26.0, again through the debug
self-test (`FMAC_SELFTEST_TABLE`, `FMAC_SELFTEST_WIZARD`) instead of the
mouse and keyboard, in Ivory and Charcoal.

- [x] Tests: `TableFormatter` (lining up, beam letters over their cells,
      comments, tuplets, Tab order, add/delete column, template, include
      line, locations outside the text); 12 engraves of tables with exact
      MIDI and no warnings; the Piano (tables) project and a violin with
      two pianos as tables engrave, score and parts.
- [x] Insert Piano Table on an empty line of a piano score: the
      `\include "piano-tables.ily"` line goes after `\version`, the file is
      written beside the score, the first cell is selected, and the
      project sidebar lists the include.
- [x] Typing eight cells with Tab between them (the editor's own
      insertText and insertTab): the columns and beam letters stay lined
      up after each one; ⇧Tab from the first cell goes to the last beam
      letter.
- [x] Add Table Column after `e''` and typing `g''` in it; Delete Table
      Column; the engrave after has no messages and shows the cross-staff
      sixteenths.
- [x] `\col` shows as a thin grey bar in both themes.
- [x] New Score: "Piano (tables)" under Solo and Duo, "Type the piano as
      tables" on under Note Entry, and the preview's first bar empty (the
      table) with rests after it.
- [x] Bug found and fixed: `TableFormatter.table(containing:)` overflowed
      for `NSNotFound`.
- [ ] Undo of the table commands: the self-test can't check it (without
      events NSUndoManager keeps one group open); they use the same
      one-step `replace` as Adjust and the Tools menu.
- [ ] By hand: typing with the real keyboard (key repeat, deleting across
      a `\col`), the menu shortcuts ⌃⌘] and ⌃⌘[, Create… in New Score up
      to the save panel.
- [x] Rows written as `\relative c'' { \col … }`, and a table inside an
      outer `\relative` (engrave test).

## 2j. Export MIDI and MusicXML

Checked on 2026-11-04 with LilyPond 2.26.0, in the app (Charcoal, and light
mode with `-NSRequiresAquaSystemAppearance YES`) and in tests.

- [x] File > Export MIDI… and Export MusicXML… sit under Export PDF…; the
      save sheet offers `<score>.midi` / `<score>.musicxml` in the score's
      folder; the status says "Exporting MusicXML…" and then "Exported
      quartet.musicxml"; Engrave turns into Stop meanwhile.
- [x] A New Score project (clarinet and piano): the MusicXML validates and
      has the clarinet written in E major with `<transpose>`; the MIDI is
      the score's own.
- [x] A score without `\midi`: "Exported nomidi.midi, with a \midi block
      added"; the file matches `\unfoldRepeats` + `\midi` typed by hand.
- [x] A score with an error: "Couldn't export broken.ly" with LilyPond's
      message, and no file written; no temporary folders are left.
- [x] Tests: 27 exports (every New Score preset, a song with lyrics,
      repeats, endings, tuplets, grace notes and a two-voice piano) validate
      against the MusicXML 4.0 XSD; the MCP `export` tool writes MusicXML and
      MIDI.
- [x] A scratch copy of Mahler 9: 39 parts, 454 bars each, valid; 72 s.
- [ ] Opening the files in MuseScore, Dorico, Sibelius or Finale: not
      tried. Check how they read voices across staves, lyrics and endings.
- [ ] Export MIDI on a score whose MIDI is up to date copies it without
      engraving: covered by the code path, not watched in the app.
- [ ] Untitled documents and projects with their own `-dinclude-settings`
      (wrapped by a generated settings file; unit-tested only).

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
