#!/bin/bash
# Build a release binary and assemble build/Kato.app (no Xcode project needed).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="build/Kato.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kato "$APP/Contents/MacOS/Kato"

# App icon: crop the rounded tile out of the black margin, apply the
# Apple-style rounded-rect alpha mask, emit an .iconset, compile to .icns.
# Needs python3 with PIL + numpy; falls back to the Kimi managed runtime.
echo "==> building Kato.icns"
PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! "$PYTHON_BIN" -c 'import PIL, numpy' 2>/dev/null; then
    for candidate in \
        "$HOME/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/python/.venv/bin/python3" \
        "$HOME/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/python/bin/python3"; do
        if [ -x "$candidate" ] && "$candidate" -c 'import PIL, numpy' 2>/dev/null; then
            PYTHON_BIN="$candidate"
            break
        fi
    done
fi
if ! "$PYTHON_BIN" -c 'import PIL, numpy' 2>/dev/null; then
    echo "error: no python3 with PIL + numpy found (set PYTHON_BIN)" >&2
    exit 1
fi
"$PYTHON_BIN" Scripts/make-icon.py Assets/Mascot/kato-appicon.png build/Kato.iconset
iconutil -c icns build/Kato.iconset -o "$APP/Contents/Resources/Kato.icns"

# Ship the mascot artwork inside the bundle so AssetLoader finds it via
# Bundle.main.resourceURL in packaged mode.
cp -R Assets "$APP/Contents/Resources/Assets"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Kato</string>
    <key>CFBundleIconFile</key>
    <string>Kato</string>
    <key>CFBundleIdentifier</key>
    <string>dev.kato.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Kato</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Kato uses Accessibility APIs to raise the terminal window/tab that needs your attention.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

# Optional: put the CLI on PATH.
if mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    ln -sf "$PWD/.build/release/Kato" "$HOME/.local/bin/kato"
    echo "==> symlinked ~/.local/bin/kato -> $PWD/.build/release/Kato"
fi

echo "==> done: $APP"
echo "    run with: open $APP   (or: .build/release/Kato)"
