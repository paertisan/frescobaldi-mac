#!/bin/bash
# Builds build/Frescobaldi.app (arm64, ad-hoc signed).
#
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-app.sh
#
# Options (environment): CONFIG=debug|release (default release),
# OPEN=1 to launch the app afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Frescobaldi.app"
CONFIG="${CONFIG:-release}"

# python-ly 0.9.10 wheel from PyPI, pinned by hash.
PYLY_URL="https://files.pythonhosted.org/packages/4f/7b/5f246bbd2626340f8778a11f4074a4151c99c2eb818d1569336b2b85de24/python_ly-0.9.10-py3-none-any.whl"
PYLY_SHA256="2164e705e42ebf5af511c4fd45fcc1158737bd702fd5f238420a48acd22c00f5"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "build-app.sh builds the macOS app and needs macOS with Xcode." >&2
    exit 1
fi

echo "==> Building Frescobaldi and frescobaldi-mcp ($CONFIG, arm64)"
swift build -c "$CONFIG" --arch arm64 --product Frescobaldi
swift build -c "$CONFIG" --arch arm64 --product frescobaldi-mcp
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

if [[ ! -f "$BUILD/python/ly/__init__.py" ]]; then
    echo "==> Fetching python-ly 0.9.10"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/python_ly.whl" "$PYLY_URL"
    echo "$PYLY_SHA256  $tmp/python_ly.whl" | shasum -a 256 -c - >/dev/null
    unzip -q "$tmp/python_ly.whl" -d "$tmp/wheel"
    rm -rf "$BUILD/python"
    mkdir -p "$BUILD/python"
    cp -R "$tmp/wheel/ly" "$BUILD/python/"
    find "$tmp/wheel" -path '*dist-info*' -iname 'LICENSE*' -exec cp {} "$BUILD/python/LICENSE-python-ly" \; || true
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/python"
cp "$BIN/Frescobaldi" "$APP/Contents/MacOS/Frescobaldi"
# The MCP server Claude runs (see Settings > Claude).
cp "$BIN/frescobaldi-mcp" "$APP/Contents/Helpers/frescobaldi-mcp"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/Templates" "$APP/Contents/Resources/Templates"
cp "$ROOT/Resources/python/fmac_lytool.py" "$APP/Contents/Resources/python/"
cp -R "$BUILD/python/ly" "$APP/Contents/Resources/python/ly"
[[ -f "$BUILD/python/LICENSE-python-ly" ]] && cp "$BUILD/python/LICENSE-python-ly" "$APP/Contents/Resources/python/"
cp "$ROOT/../frescobaldi/icons/org.frescobaldi.Frescobaldi.icns" "$APP/Contents/Resources/Frescobaldi.icns"
cp "$ROOT/../LICENSE" "$APP/Contents/Resources/LICENSE"
find "$APP" -name '__pycache__' -prune -exec rm -rf {} +
find "$APP" -name '.DS_Store' -delete

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/frescobaldi-mcp"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
if [[ "${OPEN:-0}" == "1" ]]; then open "$APP"; fi
