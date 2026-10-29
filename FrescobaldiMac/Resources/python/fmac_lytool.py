"""Run a python-ly edit on (part of) a LilyPond document.

Frescobaldi for macOS runs this with `python3 -I fmac_lytool.py <python-ly dir>`
and a JSON request on stdin:

    {"text": "...", "start": 0, "end": null, "command": "transpose",
     "args": {"from": "c", "to": "d"}, "indentWidth": 2}

start/end are offsets in Unicode code points (null end = end of document).
The whole document is passed even for a selection so that python-ly sees
`\\language`, `\\version` and enclosing `\\relative` blocks, the way
Frescobaldi itself calls python-ly.

Writes {"text": "<new document>"} or {"error": "..."}
to stdout as JSON.

Commands: transpose (from, to), translate (language), rel2abs, abs2rel,
simplify_accidentals, indent, reformat.
"""

import json
import re
import sys


def main():
    sys.path.insert(0, sys.argv[1])
    import ly.docinfo
    import ly.document
    import ly.indent
    import ly.pitch

    request = json.load(sys.stdin)
    doc = ly.document.Document(request["text"], "lilypond")
    cursor = ly.document.Cursor(doc, request.get("start") or 0, request.get("end"))
    command = request["command"]
    args = request.get("args") or {}

    info = ly.docinfo.DocInfo(doc)
    language = info.language() or "nederlands"
    version = info.version()
    # LilyPond 2.18+ reads the first pitch of \relative as absolute. Without a
    # \version statement, assume a current LilyPond.
    first_pitch_absolute = not version or version >= (2, 18)

    def indenter():
        i = ly.indent.Indenter()
        i.indent_width = int(request.get("indentWidth") or 2)
        i.indent_tabs = bool(request.get("indentTabs"))
        return i

    try:
        if command == "transpose":
            import ly.pitch.transpose
            def pitch(text):
                m = re.fullmatch(r"([a-z]+)([,']*)", text.strip())
                r = m and ly.pitch.pitchReader("nederlands")(m.group(1))
                if not r:
                    raise ValueError("not a pitch: " + text)
                return ly.pitch.Pitch(*r, octave=ly.pitch.octaveToNum(m.group(2)))
            transposer = ly.pitch.transpose.Transposer(pitch(args["from"]), pitch(args["to"]))
            ly.pitch.transpose.transpose(cursor, transposer, language, first_pitch_absolute)
        elif command == "simplify_accidentals":
            import ly.pitch.transpose
            ly.pitch.transpose.transpose(cursor, ly.pitch.transpose.Simplifier(), language,
                                         first_pitch_absolute)
        elif command == "translate":
            import ly.pitch.translate
            target = args["language"]
            if target not in ly.pitch.pitchInfo:
                raise ValueError("unknown language: " + target)
            changed = ly.pitch.translate.translate(cursor, target, language)
            if not changed:
                ly.pitch.translate.insert_language(doc, target, version)
        elif command == "rel2abs":
            import ly.pitch.rel2abs
            ly.pitch.rel2abs.rel2abs(cursor, language, first_pitch_absolute)
        elif command == "abs2rel":
            import ly.pitch.abs2rel
            ly.pitch.abs2rel.abs2rel(cursor, language, True, first_pitch_absolute)
        elif command == "indent":
            indenter().indent(cursor)
        elif command == "reformat":
            import ly.reformat
            ly.reformat.reformat(cursor, indenter())
        else:
            raise ValueError("unknown command: " + command)
    except ly.pitch.PitchNameNotAvailable:
        json.dump({"error": "Some pitches can't be written in the target pitch-name language."},
                  sys.stdout)
        return
    except (KeyError, ValueError) as e:
        json.dump({"error": str(e)}, sys.stdout)
        return

    json.dump({"text": doc.plaintext()}, sys.stdout)


if __name__ == "__main__":
    main()
