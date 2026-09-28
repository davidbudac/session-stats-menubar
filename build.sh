#!/bin/bash
# Builds SessionStats.app.
#   --install  also copy it into /Applications and (re)launch it.
#   --dmg      build a universal (arm64 + x86_64) binary and package the app
#              into "build/Session Stats <VERSION>.dmg" for redistribution.
# Flags can be combined in any order. Set CODESIGN_IDENTITY to a Developer ID
# identity to sign with it (plus hardened runtime); default is ad-hoc ("-").
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 [--install] [--dmg]" >&2
    exit 2
}

INSTALL=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --dmg)     DMG=1 ;;
        -h|--help) usage ;;
        *)         echo "Unknown option: $arg" >&2; usage ;;
    esac
done

APP_NAME="Session Stats"
BUNDLE_ID="com.davidbudac.SessionStatsBar"
VERSION="1.5"
OUT="build/${APP_NAME}.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

# A DMG may land on either kind of Mac, so try for a universal binary. That
# needs full Xcode; with only the command line tools fall back to native.
ARCH_FLAGS=()
if [[ $DMG == 1 ]]; then
    echo "==> Compiling (release, universal)"
    if swift build -c release --disable-sandbox --arch arm64 --arch x86_64; then
        ARCH_FLAGS=(--arch arm64 --arch x86_64)
    else
        echo "    Universal build failed — falling back to native ($(uname -m)) only."
        echo "==> Compiling (release)"
        swift build -c release --disable-sandbox
    fi
else
    echo "==> Compiling (release)"
    swift build -c release --disable-sandbox
fi

BIN=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/SessionStatsBar

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

# Ad-hoc signature by default. Without a stable signature macOS treats each
# rebuild as a different app, which breaks the "Open at Login" registration.
# A real identity also gets the hardened runtime (needed for notarization).
SIGN_FLAGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--options runtime --timestamp)
codesign "${SIGN_FLAGS[@]}" "$OUT" >/dev/null 2>&1 \
    || echo "    (codesign failed — 'Open at Login' may not stick)"

echo "==> Built $OUT ($(lipo -archs "$OUT/Contents/MacOS/SessionStatsBar" 2>/dev/null || uname -m))"

if [[ $DMG == 1 ]]; then
    DMG_PATH="build/${APP_NAME} ${VERSION}.dmg"
    STAGE="build/dmg-staging"
    echo "==> Packaging ${DMG_PATH}"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    trap 'rm -rf "$STAGE"' EXIT
    # ditto keeps the code signature and extended attributes intact.
    ditto "$OUT" "$STAGE/${APP_NAME}.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGE"
    trap - EXIT
    echo "==> Built $DMG_PATH ($(lipo -archs "$OUT/Contents/MacOS/SessionStatsBar" 2>/dev/null || uname -m))"
fi

if [[ $INSTALL == 1 ]]; then
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
    [[ $DMG == 1 ]] || echo "    Or package:   ./build.sh --dmg"
fi
