#!/usr/bin/env python3
"""Convert JetBrains color schemes (.icls / .xml) into Frescobaldi themes.

    python3 -I scripts/import-jetbrains-themes.py <schemes folder> <output.json> [--id-prefix rainglow]

Used for the Rainglow collection (https://github.com/rainglow/jetbrains,
MIT, Dayle Rees): about 110 themes, each as a dark, a high-contrast dark
and a light variant. Only colors are read; the XML is treated as data.

JetBrains' language-neutral DEFAULT_* attributes are mapped onto LilyPond's
token kinds (see Theme.swift):
  keyword  <- DEFAULT_KEYWORD          command   <- DEFAULT_FUNCTION_CALL
  string   <- DEFAULT_STRING           variable  <- DEFAULT_FUNCTION_DECLARATION
  comment  <- DEFAULT_LINE_COMMENT     contextName <- DEFAULT_CLASS_NAME
  duration, number <- DEFAULT_NUMBER   property  <- DEFAULT_ATTRIBUTE
  dynamic, articulation <- DEFAULT_METADATA
  spanner  <- DEFAULT_OPERATION_SIGN   delimiter, barCheck <- DEFAULT_BRACES
  scheme   <- DEFAULT_PREDEFINED_SYMBOL
  markupText, lyricText <- DEFAULT_STRING
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET

TOKENS = {
    "keyword": "DEFAULT_KEYWORD",
    "command": "DEFAULT_FUNCTION_CALL",
    "string": "DEFAULT_STRING",
    "comment": "DEFAULT_LINE_COMMENT",
    "duration": "DEFAULT_NUMBER",
    "number": "DEFAULT_NUMBER",
    "variable": "DEFAULT_FUNCTION_DECLARATION",
    "contextName": "DEFAULT_CLASS_NAME",
    "property": "DEFAULT_ATTRIBUTE",
    "dynamic": "DEFAULT_METADATA",
    "articulation": "DEFAULT_METADATA",
    "spanner": "DEFAULT_OPERATION_SIGN",
    "delimiter": "DEFAULT_BRACES",
    "barCheck": "DEFAULT_BRACES",
    "scheme": "DEFAULT_PREDEFINED_SYMBOL",
    "markupText": "DEFAULT_STRING",
    "lyricText": "DEFAULT_STRING",
}

HEX = re.compile(r"^[0-9a-fA-F]{1,6}$")


def color(value):
    """JetBrains writes colors as hex without '#', sometimes without leading zeros."""
    if value is None or not HEX.match(value):
        return None
    return "#" + value.lower().rjust(6, "0")


def luminance(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def convert(path, id_prefix):
    root = ET.parse(path).getroot()
    if root.tag != "scheme":
        return None
    colors_element = root.find("colors")
    colors = {o.get("name"): o.get("value") for o in colors_element} if colors_element is not None else {}
    attributes = {}
    attributes_element = root.find("attributes")
    for attribute in attributes_element if attributes_element is not None else []:
        value = attribute.find("value")
        if value is not None:
            attributes[attribute.get("name")] = {o.get("name"): o.get("value") for o in value}

    text = attributes.get("TEXT", {})
    background = color(text.get("BACKGROUND"))
    foreground = color(text.get("FOREGROUND"))
    if not background or not foreground:
        return None

    tokens = {}
    for kind, key in TOKENS.items():
        value = color(attributes.get(key, {}).get("FOREGROUND"))
        if value and value != foreground:
            tokens[kind] = value

    name = re.sub(r"\s*\(rainglow\)", "", root.get("name") or os.path.basename(path)).strip()
    stem = os.path.splitext(os.path.basename(path))[0]
    variant = "light" if stem.endswith("-light") else "contrast" if stem.endswith("-contrast") else "dark"
    family = re.sub(r"\s+(Light|Contrast)$", "", name)
    theme = {
        "id": f"{id_prefix}:{stem}",
        "name": name,
        "family": family,
        "variant": variant,
        "dark": luminance(background) < 0.5,
        "background": background,
        "foreground": foreground,
        "caret": color(colors.get("CARET_COLOR")) or foreground,
        "currentLine": color(colors.get("CARET_ROW_COLOR")),
        "selection": color(colors.get("SELECTION_BACKGROUND")),
        "selectionForeground": color(colors.get("SELECTION_FOREGROUND")),
        "gutterText": color(colors.get("LINE_NUMBERS_COLOR")),
        "gutterCurrentText": color(colors.get("LINE_NUMBER_ON_CARET_ROW_COLOR")),
        "gutterBackground": color(colors.get("GUTTER_BACKGROUND")),
        "tokens": tokens,
    }
    return {k: v for k, v in theme.items() if v is not None}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    source, output = sys.argv[1], sys.argv[2]
    id_prefix = sys.argv[sys.argv.index("--id-prefix") + 1] if "--id-prefix" in sys.argv else "jetbrains"
    themes = []
    for name in sorted(os.listdir(source)):
        if name.endswith((".icls", ".xml")):
            theme = convert(os.path.join(source, name), id_prefix)
            if theme:
                themes.append(theme)
    order = {"dark": 0, "contrast": 1, "light": 2}
    themes.sort(key=lambda t: (t["family"].lower(), order[t["variant"]]))
    with open(output, "w") as f:
        json.dump({"source": "https://github.com/rainglow/jetbrains", "license": "MIT, Dayle Rees",
                   "themes": themes}, f, indent=0, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    print(f"{len(themes)} themes -> {output}")


if __name__ == "__main__":
    main()
