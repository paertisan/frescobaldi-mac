# Frescobaldi for macOS (Swift)

A native macOS front end for LilyPond, forked from
[Frescobaldi 4.0.7](https://github.com/frescobaldi/frescobaldi/releases/tag/v4.0.7).
The original PyQt6 app stays in `../frescobaldi/` as the reference
implementation; this folder replaces its UI with Swift, AppKit and SwiftUI.

**Status:** working MVP. The app builds without warnings with Xcode 27.1
(Swift 6.4) and was tested by hand on macOS 27 with LilyPond 2.26.0:
editing, engraving, point-and-click both ways, issues, MIDI, the Tools
menu, templates and Settings all work, in light and dark mode.
`FrescobaldiCore` passes its 148 tests on macOS (the ones that engrave need
LilyPond, the PDF ones PDFKit; the rest are meant to run on Linux too, last
checked there at 76 tests with Swift 6.2), and the MCP server its 14 on
macOS. Claude can work with scores through the bundled MCP server (see
below).
[MAC-CHECKLIST.md](MAC-CHECKLIST.md) lists what was checked and what is
still open.

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
| Window | `NSSplitViewController`: sidebar (outline) · editor + collapsible log (nested vertical split) · PDF preview. `fullSizeContentView`, unified `NSToolbar` with SF Symbols (Engrave turns into Stop while LilyPond runs), centered engrave status as plain text (SwiftUI in `NSHostingView`). See [Design](#design) |
| Editor | `NSTextView` on TextKit 1 (`usingTextLayoutManager: false`), Cascadia Code (or any monospaced font), current-line highlight, line-number `NSRulerView` with error/warning markers (an app-wide `IssueMarkerStore` keeps them per file: a run replaces the markers of every file it read, so a window for an include file shows its errors and a clean engrave clears them; they move with edits), auto-indent, 2-space indent, toggle comment (⌘/), shift left/right (⌘[ ⌘]), go to line (⌘L), find bar |
| Highlighting | Swift lexer in `FrescobaldiCore` (resumable state, UTF-16 `NSRange` tokens). Colors are applied as `NSLayoutManager` temporary attributes on the visible range only, with lexer-state checkpoints. Colors come from the theme (see [Themes](#themes)) |
| Engraving | `Process` running `lilypond -dpoint-and-click --pdf -o <dir/base> <abs path>`. `LANG=en_US.UTF-8` keeps messages parseable; PATH is extended with `/opt/homebrew/bin:/usr/local/bin`. Titled documents are saved first; untitled ones are written to a temp dir. Outputs come from log lines ``Converting to `x.pdf'...`` and ``MIDI output to `x.midi'...``. ⌘R preview, ⇧⌘R publish (`-dno-point-and-click`), ⌘. stop. Optional engrave on save. Export PDF engraves the source again for publishing into a temp folder, since a point-and-click PDF holds every source file's full path (PDFKit can't strip them: removed annotations stay in the file) |
| Preview | PDFKit `PDFView` that reloads while keeping page and zoom. Opening a document shows the PDF from an earlier run if it's at least as new as the source (`EngraveJob.existingOutputs`: `name.pdf` and `name-*.pdf`, so `\bookOutputSuffix` names count too, but not the outputs of a sibling target such as `name-a4.ly`; the last run's files first). Clicking a `textedit://` link jumps the editor (`showFindIndicator`); `ScoreView` handles those clicks itself (see below). Moving the editor cursor highlights the matching notes in the PDF via a link index. Floating zoom/page controls use `.glassEffect()` on macOS 26 with a material fallback. Empty state uses `ContentUnavailableView` |
| Issues/log | SwiftUI panel: Issues list (click to jump; opens included files if needed) plus raw log. It starts closed, opens when a run has errors, and closes again after a clean run if it opened by itself. Messages without a location (`warning: Unknown paper size`) are listed too and open the log; a message keeps the lines LilyPond prints after it, up to a blank line (the one that explains a Scheme error) |
| Tools | `Resources/python/fmac_lytool.py` runs python-ly's API on the whole document with a cursor over the selection (as Frescobaldi does), so `\language`, `\version` and enclosing `\relative` are respected. The CLI only sees the piped text and loses that context. Run as `python3 -I -B fmac_lytool.py <python-ly dir>` with a JSON request on stdin. Commands: transpose, translate pitch names, rel2abs/abs2rel, simplify accidentals, indent, reformat. rel2abs/abs2rel refuse music with `\resetRelativeOctave`, whose pitch python-ly reads as a note (upstream #930). The result is applied as one minimal, undoable replacement. python-ly 0.9.10 (pure Python, needs ≥3.8) is bundled in `Contents/Resources/python` |
| MIDI | `AVMIDIPlayer` with `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls` |
| Settings | `NSTabViewController` (toolbar tab style) hosting SwiftUI forms. Includes the LilyPond path with auto-detect, version, and an **arm64 / Intel (Rosetta)** badge from the Mach-O header |
| Templates | `Resources/Templates/*.ly`, ported from Frescobaldi's built-ins (`$LILYPOND_VERSION`, `$CURSOR` placeholders), and the Score Wizard (see [New Score](#new-score)) |
| Sidebar | Outline, or the project: include tree, folder and suggestions (see [Projects](#projects)) |
| Claude (MCP) | `frescobaldi-mcp` helper: file tools, plus a Unix-socket bridge to open documents. See [below](#claude-and-other-ai-clients-mcp) |

LilyPond search order: user setting, `/opt/homebrew/bin`, `/usr/local/bin`,
`/opt/local/bin`, `/opt/lilypond/bin`,
`/Applications/LilyPond.app/Contents/Resources/bin`, `~/bin`,
`~/lilypond-*/bin`.

Shortcuts follow macOS conventions. Ctrl+Cmd+F for full screen and the
Window-menu tab commands come from AppKit automatically.

## Claude and other AI clients (MCP)

`frescobaldi-mcp` (bundled as `Frescobaldi.app/Contents/Helpers/frescobaldi-mcp`)
is a [Model Context Protocol](https://modelcontextprotocol.io) server, so
Claude can engrave scores, look at the result and edit what you have open.
Settings > Claude shows the setup with the right path and a Copy button:

```bash
claude mcp add --scope user frescobaldi -- '/Applications/Frescobaldi.app/Contents/Helpers/frescobaldi-mcp'
```

For Claude Desktop, add it to `claude_desktop_config.json`
(`{"mcpServers": {"frescobaldi": {"command": "…/frescobaldi-mcp"}}}`) and
restart Claude.

| Tool | What it does |
|---|---|
| `engrave` | Runs LilyPond on a `.ly` file (an include file engraves its target, with the project's include paths and output folder) or on source text; returns errors and warnings (file, 1-based line and column, source context), PDFs and MIDI files |
| `render_page` | A PDF page as PNG, so Claude sees the score. Takes a `.pdf`, a `.ly` (its up-to-date PDF) or an open document. Long blank stretches are shortened unless `trim` is false |
| `transform` | The Tools menu via python-ly: transpose, translate pitch names, relative ↔ absolute, simplify accidentals, re-indent, reformat. On a file, text, or an open document (its selection, as one undo step) |
| `outline` | `\version`, `\include`, variables, blocks and `%%` markers with line numbers |
| `lilypond_info`, `templates` | The LilyPond in use (same setting as the app); the score templates with `\version` filled in |
| `new_score` | Creates a project as File > New Score… does, from a preset ensemble or a list of instruments, with titles, key, time, tempo and layout options; returns the files and each player's music variables, and opens the score in the app if it's running |
| `list_documents`, `get_document` | Open documents; text, selection and cursor, unsaved state, PDF, last engrave's issues |
| `edit_document` | `old_text` → `new_text` replacements (each must match once) or a whole new text, applied as one change the user can undo ("Undo Claude Edit") |
| `engrave_document` | ⌘R for an open document (saves first; its own target, or the one pinned in the target menu), waits and returns the issues |
| `reveal` | Selects a line/column range in the editor; the PDF highlights it |

File tools work without the app. The document tools talk to the running
app over a Unix socket, `~/Library/Application Support/Frescobaldi/bridge.sock`
(folder 0700, socket 0600; the app also checks the peer's user id), one
JSON request and answer per connection. Turn it off in Settings > Claude.
The protocol is implemented by hand (JSON-RPC over stdio, tools only), so
the package still has no dependencies.

Environment variables for the helper: `FRESCOBALDI_LILYPOND` (LilyPond to
use instead of the app's setting), `FRESCOBALDI_RESOURCES` (templates and
python-ly driver), `PYTHON_LY_DIR`, `FRESCOBALDI_BRIDGE_SOCKET`.

## Projects

Larger scores are usually split into files: the music in one include file
per instrument, shared settings in a style sheet, and small `.ly` files
that put the score and the parts together. The app helps with that, and
takes up Frescobaldi's wishes for projects
([#1301](https://github.com/frescobaldi/frescobaldi/issues/1301),
[#1069](https://github.com/frescobaldi/frescobaldi/issues/1069),
[#798](https://github.com/frescobaldi/frescobaldi/issues/798)) without
a project dialog to fill in first:

- **Targets.** The files to engrave are the `.ly` files that make output
  by themselves (a top-level `\score`, `\book`, `\bookpart`, music or
  `\markup`, also through files they include at top level), except ones
  only used inside another file's music. The project folder is the main
  file's folder, or the one above it when the main file includes files
  from there (as `parts/flute.ly` includes `../music/flute.ily`), or
  wherever `frescobaldi.json` is.
- **What ⌘R engraves.** The toolbar's target menu works like Xcode's
  scheme menu. *Automatic* engraves the current file's target: the file
  itself if it's a target, its `-*- master: ...;` document variable
  (Frescobaldi's convention), or a target that includes it (the default
  target if several do). You can also pin one target, choose All Targets
  (⌥⌘R; a few LilyPond runs at a time) or a build command. The choice is
  kept per project folder. Edited files of the project are saved first;
  issue markers and cursor highlighting stay on the file being edited.
  An include file nothing uses, or a `.ly` with only definitions, isn't
  engraved alone: an alert says why and offers the main target.
- **`frescobaldi.json`.** LilyPond > Project Settings… (or the gear in the
  sidebar) writes it at the project folder, and only when a setting
  changes. Everything is optional:

  ```json
  {
    "targets": ["score.ly", "parts/flute.ly"],
    "defaultTarget": "score.ly",
    "includePaths": ["../openlilylib"],
    "outputDirectory": "build",
    "commands": [{ "name": "Parts", "command": "make parts", "directory": "." }]
  }
  ```

  Without `targets` they're found as above. Include paths go to LilyPond
  as `-I` and are used by the include tree too. With an output folder
  PDFs and MIDI files go there (`build/flute.pdf`), and existing ones are
  found there on open. Build commands run with `/bin/sh` in the project
  folder (or `directory`); LilyPond's messages in their output become
  clickable issues, also when make runs LilyPond in another folder, and
  the PDF reloads. Commands from a project file run only after you've
  seen and allowed each one; the ones you type in Project Settings don't
  ask.
- **Project sidebar.** Switch the sidebar from Outline to Project for the
  targets (with a button that engraves each), the include tree from the
  main file (resolved as LilyPond 2.26 does: relative to the including
  file, then the main file's folder, then the include paths, then
  LilyPond's own `ly` folder), the project folder, and suggestions:
  missing includes and cycles, absolute paths (the project won't build on
  another computer), files outside the project, `.ly` files used as
  includes, `.ily` files nothing includes, a file with nothing to
  engrave, a main file without `\version`, problems in
  `frescobaldi.json`. Libraries the project uses don't get organization
  hints. Clicking a file opens it as a tab, at the line in question.
- **New Score** (⌥⌘N) creates that layout for any ensemble: see below.

## New Score

File > New Score… (⌥⌘N) sets up a project to start entering music in.
It has four steps, with the start of the score engraved beside them as
you go (click it for the whole page). Create… works from any step and
asks where to put the project folder.

- **Ensemble.** 24 presets (solo and duo, chamber music, choir, orchestra
  and band, songs and bands), or any players from 58 instruments in the +
  menu ([#289](https://github.com/frescobaldi/frescobaldi/issues/289),
  [#2196](https://github.com/frescobaldi/frescobaldi/issues/2196)). New
  players go in score order; drag to reorder, click a name to rename one
  ("Solo Violin"). Several of one instrument are numbered as scores do:
  Violin I and II, Horn 1 and 2 in F. Brackets go by family, around
  everything, or nowhere. Save Ensemble… keeps a set of players under My
  Ensembles.
- **Music.** Key and mode, time signature (C and ¢, or numbers), pickup,
  empty bars to start with
  ([#1313](https://github.com/frescobaldi/frescobaldi/issues/1313)), tempo
  words and metronome mark, pitch names (`\language`), octave entry
  (`\relative`, `\fixed` or absolute), and for transposing instruments,
  concert or written pitch and a transposed score or one in C.
- **Titles.** Title, subtitle, dedication, composer, arranger, poet, opus,
  copyright; LilyPond's tagline is off unless you want it.
- **Layout.** Paper size and orientation
  ([#1142](https://github.com/frescobaldi/frescobaldi/issues/1142)), staff
  size of the score (by default 20 down to 12, by the number of staves)
  and of the parts, instrument names, hiding staves with only rests after
  the first system, MIDI, parts.

The wizard remembers the composer, pitch names, entry mode, paper and the
last ensemble. What it writes:

```text
serenade/
  serenade.ly          the score: engrave this
  header.ily           titles, shared by the score and the parts
  style.ily            paper and layout, shared by the score and the parts
  music/global.ily     key, time, tempo, and the bars as skips
  music/flute.ily      the music, one file per player
  parts/flute.ly       one part per player
```

- A player's music is in one file that the score and the part both use,
  so a correction reaches both.
- `\global` runs alongside each player's music (`<< \global \flute >>`)
  and holds the bars as skips, so rehearsal marks, key changes and double
  bar lines are written once, at their bar.
- Transposing instruments are entered at concert pitch: you write what
  sounds, and the score and parts show what the players read
  (`\transposition` and `\transpose`). The key is spelled so that no part
  gets more than six sharps or flats: a B♭ clarinet in concert B major
  reads D♭ major. Octave transpositions (piccolo, double bass,
  glockenspiel) are entered as written, as every score prints them.
  Entering as written and a score in C are options; a score in C keeps
  octave transpositions, so a tenor saxophone stays in the treble clef.
- The MIDI file comes from a second `\score` with `\unfoldRepeats`, so
  repeats play. Above 15 staves it uses one MIDI channel per instrument
  rather than per staff (MIDI has 16).
- Every `.ily` names the score as its master, so ⌘R in any of them
  engraves the score; each part is a target of its own.

Every preset and a set of option combinations (all six pitch-name
languages, keys from D♭ major to C♯ major, 5/4 and 7/8, pickups, both
entry modes, a score in C) engrave with LilyPond 2.26 without errors or
warnings, score and parts (`ProjectTemplateTests`). Blank staff paper
([#1139](https://github.com/frescobaldi/frescobaldi/issues/1139)) was
already a template: File > New from Template > Blank Music Paper.

## Adjusting objects in the preview

Drag articulations, dynamics, texts, fingerings, hairpins, pedal marks,
tuplet brackets, slurs, ties and beams in the PDF preview, and the app
writes the change into the source as plain LilyPond: a `-\tweak`, a
`-\shape`, an `\offset`, or an override before the note. The score keeps
compiling with plain LilyPond anywhere; nothing needs an include file.

The idea comes from Paolo Prete's
[Spontini Editor](https://github.com/paopre/Spontini), which does this in a
browser on LilyPond's SVG output with its own `\jsTweak` commands. This is a
separate implementation from its documentation and behaviour (no Spontini
code or `.ly` files; Spontini is GPL-3.0) that works on the PDF preview.

**Using it.** Turn on Adjust in the toolbar (View > Adjust Objects in
Preview, ⇧⌘A), or hold ⌥ for one drag. The object under the pointer gets a
thin clay outline and a tooltip ("Dynamic · mf · line 12", plus the file
name when it's in an included file). Dragging shows the object following
the pointer; on release the tweak is written as one undoable change (Edit >
Undo Adjust Dynamic) and the score engraves again. Shift keeps the drag
horizontal or vertical. A click without dragging shows the object in the
source. Slurs, phrasing slurs and ties show their four control points and
beams their two ends as handles. Objects written in an included file are
changed there: the file opens as a tab behind the score's (the change is
undone in that tab). A drag is refused, with a word in the toolbar, while
an engrave runs or when the source changed since the preview.

**What a drag writes.** A plain drag sets `extra-offset`. Right-click an
object to choose instead X-offset, Y-offset, Padding, Distance from Staff
(`staff-padding`) or Outside-Staff Padding, as far as the object has them;
the choice is kept per kind of object until the app quits. The
collision-aware properties of dynamics, hairpins and pedals go to their
`DynamicLineSpanner` / `SustainPedalLineSpanner`, on the event that made
that spanner (for `\p\<` that's the hairpin). Values are rounded to 0.01
staff space; moves under 0.05 staff space are ignored. A second drag
updates the tweak that's there instead of adding one.

| Object | Source | Becomes |
|---|---|---|
| Articulation, dynamic, text, fingering, hairpin, pedal | `c4->`, `c4^.`, `f\p`, `a^"dolce"`, `g-1` | `c4-\tweak extra-offset #'(1.2 . -0.5) ->`, `c4-\tweak extra-offset #'(…) ^.` |
| Collision property of a dynamic | `c4\p\<` | `c4\p-\tweak DynamicLineSpanner.staff-padding #3.1 \<` |
| Slur, phrasing slur, tie (handle) | `c8( d e f)` | `c8-\shape #'((0 . 0) (0 . 1.5) (0 . 1.5) (0 . 0)) ( d e f)`; for a slur broken across lines, `#'(() ((…)))` for the second piece |
| Beam end | `c8[ d e f]` | `c8-\offset positions #'(1 . 0) [ d e f]` |
| Automatic beam (no `[`) | `c8 d e f` | `\once \offset positions #'(1 . 0) Beam c8 d e f` (before the chord in `<c e>8`) |
| Tuplet bracket | `\tuplet 3/2 { … }` | `\tweak TupletBracket.padding #1.2 \tuplet 3/2 { … }` |

**How it works.** Preview engraves (never Engrave for Publishing, Export
PDF or build commands) pass `-dinclude-settings=Resources/LilyPond/fmac-edit.ly`
(LilyPond 2.24 or later; a project's own `-dinclude-settings` wins). Its
Score engraver wraps the stencil of each of these grobs with an invisible
`url-link` (what `\with-url` draws), so PDFKit gives an annotation with the
object's exact rectangle. The URL, `fmac://grob?name=…&line=…&char=…&…&file=…`,
holds the event's location (0-based character column; the start of any
tweaks already on it), the event class, a label, the units (mm per staff
space and per LilyPond unit), the stencil's extents, and the values a drag
starts from: `extra-offset`, the X and Y offsets, `padding`,
`staff-padding`, `outside-staff-padding` and `direction` (of the side
spanner where there is one), slur control points and beam positions, and
which piece of a broken spanner it is. The URL is built in a
`delay-stencil-evaluation` stencil, so it's computed when the page is
written, after layout: reading the offsets can't change the layout or add
warnings. On the 58-page Mahler 9/I score the PDF has the same 45,681
point-and-click rectangles and the same 40 warnings with and without the
file, plus 17,641 adjustable objects; it engraves in 103.7 s instead of
103.1 s (CPU time +4%), and the PDF grows from 14.8 to 22.2 MB. `GrobLink` (Core) parses the URL and
turns a drag into a `Tweak`; `TweakWriter` (Core) writes it as one minimal
replacement using the source text, LilyPond's columns (tabs count as one
character, columns are Unicode characters) and the lexer for chords.

**Limits.** Moving an object that comes from a variable or a music function
tweaks its definition, which changes every use. Tweaks are written where
LilyPond says the event is, so a drag after editing without engraving is
refused rather than guessed. A `\shape` or `\offset` value written as Scheme
code (`#(list …)`) isn't merged; the drag says so. Undo of a change in an
included file is in that file's tab. No MCP tool for it yet: Claude can
write the same tweaks with `edit_document`.

## Piano tables

Both staves of a piano passage can be typed together, as a table: a row
for the upper staff and one for the lower, with `\col` between the
columns, and above them where each column's beam goes. Notes from both
rows that share a beam become one voice that changes staff, so cross-staff
beams, arpeggios and split chords come out right, and the MIDI plays every
note once. Spontini's `\easyCrossStaff` tables are the inspiration; this is
our own implementation (`Resources/LilyPond/piano-tables.ily`, plain
LilyPond and Scheme), written into the project so the score compiles
anywhere.

```lilypond
\include "piano-tables.ily"

pianoRight = {
  \clef treble
  \pianoTable
    #'(    C          -      -        - )
    { \col c''16[ \col s \col e'' \col s   \col }
    { \col s16    \col g \col s   \col c'] \col }
  r2
}
```

- **Beam row** (optional, first): `U` above (stems up), `D` below, `C`
  between the staves, `N` no cross-staff (each row its own voice in its
  staff), `-` as before; without it LilyPond chooses. (LilyPond can't skip
  an optional argument at the end of a music function, so the list comes
  before the rows rather than after them as in Spontini.)
- **Columns**: one stretch of time. Both cells have the same length, or one
  is empty. A note in only one row goes to that row's staff; notes in both
  are joined into one stem (`\crossStaff`, with `Span_stem_engraver` on the
  PianoStaff). A beam or slur written on a skip (`s8]`) moves to the note
  in the other row. A `\tuplet` may span columns (with `\col` inside it in
  both rows) and keeps one bracket.
- **`\pianoTablePoly 2 { {row} {row} {row} }`**: one row per voice, the
  first two in the upper staff (`\voiceOne`, `\voiceTwo`, …), the rest in
  the lower; columns there only line things up.
- Pitches are absolute (c' is middle C), also inside `\relative`, which
  continues after the table from the note before it. The staves are found
  by name, "right" and "left" as New Score makes them
  (`pianoTableStaves = #'("upper" . "lower")` for others).

**In the editor.** Tools > Insert Piano Table puts an empty table (four
eighth-note columns) at the insertion point with its first cell selected,
and if needed writes `piano-tables.ily` beside the file and adds the
`\include` after `\version`, as one undo step. As you type in a table, its
columns stay lined up (`TableFormatter` in Core moves only spaces, and the
caret stays in its cell). Tab and ⇧Tab select the next and previous cell,
across rows; Add Table Column (⌃⌘]) and Delete Table Column (⌃⌘[) work on
every row and the beam letter. `\col` is drawn as a thin grey bar.

**New Score.** The "Piano (tables)" preset, or "Type the piano as tables"
under Note Entry for any score with a piano: the project gets
`piano-tables.ily` (included by the score and the piano part), and the
piano's music starts with a one-bar table of beats in the right hand; the
left hand's variable keeps its staff going. Several pianos get their own
`pianoTableStaves`. The `new_score` MCP tool takes `piano_tables`.

**Tests.** Engraves of every case with LilyPond (no errors or warnings,
and the MIDI's notes and times exact): sixteenths crossing between the
staves, beams above and below, split chords, `N` with rests, a triplet
across the staves, a rising arpeggio and a lower-row chord, no beam list,
`\relative` rows, polyphony, and the musical content of three Spontini examples (its
cross-staff examples 1 and 2 and its polyphonic table, rewritten as our
tables; in example 2's C - U D N pattern the kneed pair is E–G instead of
two middle Cs, where a beam between the staves has no room).

## Design

The window aims for the quiet, content-first look of apps like Claude's
desktop app, Linear and Things: the score and the source are what you
look at, and the chrome steps back.

- **Warm neutrals, one accent.** Ivory (light) and Charcoal (dark) use the
  background, sidebar and text greys of Claude's apps (#FAF9F5 / #F5F4ED /
  #73726C, #262624 / #1F1E1D / #9C9A92) and a clay accent (#C6613F,
  #D97757 in dark mode), which is also the app's accent color
  (`Resources/Assets.xcassets`, compiled by `actool`). The notes are the
  plainest text; commands, durations and comments step back in a few muted
  colors, all at 4.5:1 contrast or more.
- **Status as words.** The toolbar says "Engraved in 0.4 s" in grey, or
  "Engraving failed · 1 error · 1 warning"; only problems get color, and
  errors and warnings differ in shape as well as color. Nothing is shown
  for "ready" except a faint ⌘R hint.
- **Panels when there's something in them.** The issues panel opens for
  errors and closes after a clean run; the project's suggestions are folded
  to a count; the run buttons of targets show on hover.
- **Fewer controls.** One Engrave button that becomes Stop, a target menu
  without a repeated icon, text tabs instead of segmented controls in the
  sidebar and the issues panel.
- **A serif for headings.** Empty panes and the wizard's ensemble title use
  New York; everything else is the system font.
- **The New Score window** follows the theme like the document windows.

## Themes

Settings > Editor sets the font (default Cascadia Code if installed;
Cascadia Mono has no coding ligatures) and a theme for light mode and one
for dark mode; the app follows the system appearance. A theme colors the
whole window: editor, syntax, gutter, current line, toolbar, sidebar,
issues panel and the area around the PDF, and gives the window the
matching light or dark appearance.

Built in: Ivory and Charcoal (the defaults; see [Design](#design)), and
from each project's official palette Everforest Dark and Light, Nord,
Catppuccin Frappé and Latte, Monokai, and System (the system colors). Plus the 326 themes of the
[Rainglow](https://github.com/rainglow/jetbrains) collection (MIT, Dayle
Rees), converted from JetBrains color schemes by
`scripts/import-jetbrains-themes.py` into `Resources/Themes/rainglow.json`:

```bash
python3 -I scripts/import-jetbrains-themes.py <folder of .icls/.xml> Resources/Themes/rainglow.json --id-prefix rainglow
```

The theme browser searches them all and previews each on a line of
LilyPond.

## Verified facts (LilyPond 2.26.0, macOS 27)

- PDFKit exposes LilyPond links as `PDFAnnotation.url`, in the form
  `textedit:///abs/path.ly:LINE:START:END`. LINE is 1-based; START/END are
  0-based character columns of the note.
- Log messages look like `file:LINE:COL: error|warning: text`, where COL is
  **1-based**. The two following lines show the source split at the error.
  `fatal error: failed files: …` is a summary and can be skipped.
- A PDF is still produced when there are errors.
- PDFKit doesn't call `pdfViewWillClick(onLink:with:)` for these links.
  Mouse events go to PDFKit's internal subviews, and its gesture handling
  swallows the mouse-up. `ScoreView` claims points over `textedit://` links
  in `hitTest` and tracks the click in `mouseDown`.
- Views don't clip to their bounds (since macOS 14), and a ruler's dirty
  rect can reach over the text view, so `LineNumberRuler` clips and fills
  only its bounds.
- SwiftUI hosting controllers inside split view items need
  `sizingOptions = []`, or the window shrinks to their ideal sizes.
- `-\tweak prop val` goes before a post-event *with* its direction:
  `c4-\tweak extra-offset #'(1 . 2) ^.` works, but `c4^\tweak … .` and
  `c4^\tweak … \markup …` are syntax errors.
- An event's `origin` points at the start of the tweaks already on it
  (`-` of `-\tweak`, `\` of `\tweak TupletBracket.padding … \tuplet`).
  `ly:input-file-line-char-column` gives (file line char column): char
  counts a tab as one, column expands it.
- The `DynamicLineSpanner` of `\p\<` is caused by the hairpin; a
  `-\tweak DynamicLineSpanner.staff-padding` on the `\p` does nothing.
- `extra-offset` is in staff spaces of the object's staff (`\magnifyStaff #2`
  doubles it). `\shape` scales y by staff space only in its single-list
  form, and a single list on a broken slur shapes the first piece only.
- Unset `outside-staff-padding` behaves as 0.46.
- A `delay-stencil-evaluation` stencil is forced when the page is output
  (after "Drawing systems..."), not by skyline or extent calculations.
- `python3 -m ly "transpose c d"` and `ly "translate english"` read stdin and
  write stdout. Languages: nederlands, catalan, deutsch, english, espanol,
  italiano, norsk, portugues, suomi, svenska, vlaams.

## Building

Requires Xcode 27+ (the macOS 26+ SDK gives the Liquid Glass look). The build
targets arm64 only; deployment target is macOS 14.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh                 # → build/Frescobaldi.app (OPEN=1 to launch it)
PYTHON_LY_DIR=build/python swift test
```

`scripts/build-app.sh`:
- runs `swift build -c release --arch arm64`
- downloads the python-ly 0.9.10 wheel once into `build/python` (pinned by
  SHA-256)
- assembles `Frescobaldi.app` with `Info.plist` (bundle id
  `io.github.paertisan.frescobaldi`; imported UTIs
  `org.lilypond.lilypond-source` for .ly and `org.lilypond.lilypond-include`
  for .ily/.lyi, plus `public.plain-text` as an alternate type, all with
  `NSDocumentClass` = `LilyPondDocument`)
- copies `../frescobaldi/icons/org.frescobaldi.Frescobaldi.icns`, the
  templates, the python-ly driver and python-ly into the bundle
- ad-hoc signs the bundle

A debug build (`CONFIG=debug scripts/build-app.sh`) can drive Adjust in
the running app without screen control, for checking it after changes:

```bash
FMAC_SELFTEST=/path/to/score.ly FMAC_SELFTEST_OUT=/tmp/adjust build/Frescobaldi.app/Contents/MacOS/Frescobaldi
```

It opens the score, engraves, drags an articulation, a dynamic, a slur
handle and a beam end with posted mouse events, undoes the last one, and
writes window snapshots and `report.txt` (it edits the score: use a copy).
`FMAC_SELFTEST_INCLUDE=1` drags an object from an included file instead;
`FMAC_SELFTEST_TABLE=1` inserts a piano table into the score (it needs an
empty line before an `r2`) and types into it; `FMAC_SELFTEST_WIZARD=1`
(with any `FMAC_SELFTEST` value) opens New Score with the Piano (tables)
preset.

The python-ly tests are skipped unless python-ly is found: they use
`$PYTHON_LY_DIR` or `build/python`.

On Linux, `swift test` builds and tests `FrescobaldiCore` only; the app
target is macOS-only in `Package.swift`.

## Layout

| Path | What |
|---|---|
| `Sources/FrescobaldiCore` | UI-free logic: `LilyPondLexer` (+ generated `LilyPondWords`), `TextEditLink`, `LilyPondLogParser`, `LilyPondLocator`, `DocumentOutline`, `EngraveJob`, `PythonLyTool`, `LilyPondTemplate`, `PointAndClickIndex`, `TextEditing` (+ `TextSubstitution`), `LineIndex`, `IssueMarkers` (+ `LineEdit`), `LilyPondProject` (include tree, main file, folder, suggestions, `DocumentVariables`), `Instruments` (`Pitch`, `PitchLanguage`, `Instrument`), `ScoreSpec` (+ `Ensemble`, `KeySignature`, `TimeSignature`), `ProjectTemplate` (writes a project from a `ScoreSpec`), `GrobLink` + `AdjustProperty` (preview objects), `TweakWriter` (+ `Tweak`), `TableFormatter` (piano tables in the source) |
| `Sources/Frescobaldi` | The app: `main.swift`, `AppDelegate`, `MainMenu`, `DocumentController`, `LilyPondDocument`, `DocumentWindowController` (layout, toolbar, engraving, tools, MIDI), `EditorViewController`/`LilyTextView`/`LineNumberRuler`/`SyntaxHighlighter`, `PreviewViewController`, `EngraveModel` (status, issues and log views), `OutlineSidebar`, `ProjectNavigator` (sidebar), `Theme` (themes, `ThemeStore`), `MIDIPlayer`, `SettingsWindowController`, `Preferences`, `ClaudeBridge`, `ScoreWizard` (+ `ScoreWizardPreview`), `AdjustOverlay` (dragging in the preview), `AdjustSelfTest` (debug builds only) |
| `Sources/FrescobaldiMCP` | MCP server (`MCPServer`, `JSONValue`), the tools (`FrescobaldiTools`), the app bridge (`Bridge`: socket client and server), `PageRenderer`, shared `EngraveReport`, `NewScore` (`new_score` arguments) |
| `Sources/frescobaldi-mcp` | The helper's `main.swift` |
| `Resources` | Templates, themes (`Themes/rainglow.json` + license), the python-ly driver, `LilyPond/fmac-edit.ly` (preview links) and `LilyPond/piano-tables.ily` (piano tables), copied into the bundle |
| `scripts/gen-lilypond-words.py` | Regenerates `LilyPondWords.swift` from a python-ly checkout |
| `scripts/import-jetbrains-themes.py` | Converts JetBrains color schemes into a theme collection |

SPM resource bundles aren't used, because they break app-bundle signing.

## Roadmap after the MVP

Snippets/quick insert, bracket matching, document-wide
transpose with context, MusicXML import (`musicxml2ly`), multiple-PDF picker,
dark "paper" option, notarized DMG.

## License

GPL-2.0-or-later, same as Frescobaldi and python-ly.
