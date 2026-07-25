#!/bin/bash
# Builds SessionStats.app. Pass --install to also copy it into /Applications
# and (re)launch it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Session Stats"
BUNDLE_ID="com.davidbudac.SessionStatsBar"
VERSION="1.0"
OUT="build/${APP_NAME}.app"

echo "==> Compiling (release)"
swift build -c release --disable-sandbox

BIN=$(swift build -c release --show-bin-path)/SessionStatsBar

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/SessionStatsBar"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>SessionStatsBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without a stable signature macOS treats each rebuild as a
# different app, which breaks the "Open at Login" registration.
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT" >/dev/null 2>&1 \
    || echo "    (codesign unavailable — 'Open at Login' may not stick)"

echo "==> Built $OUT"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}"
    pkill -f "SessionStatsBar" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$OUT" "$DEST"
    open "$DEST"
    echo "==> Running. Look for the token counts in your menu bar."
else
    echo "    Run it with:  open '$OUT'"
    echo "    Or install:   ./build.sh --install"
fi
