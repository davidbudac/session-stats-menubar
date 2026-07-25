#!/bin/bash
# Builds the app and packages it as build/Session-Stats.dmg.
# Pass a tag (e.g. ./release.sh v1.0) to also publish a GitHub release.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Session Stats"
DMG="build/Session-Stats.dmg"
STAGING="build/dmg"

./build.sh

echo "==> Staging disk image contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "build/${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # the usual drag-to-install target

echo "==> Creating ${DMG}"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"

if [[ $# -ge 1 ]]; then
    TAG="$1"
    echo "==> Publishing release $TAG"
    gh release create "$TAG" "$DMG" \
        --title "$APP_NAME $TAG" \
        --notes-file <(cat <<'NOTES'
Today's Claude Code token usage, per model, in the menu bar.

**Install:** open the DMG, drag **Session Stats** to Applications. The app is
ad-hoc signed and not notarized, so the first launch needs **right-click → Open**
(double-clicking will refuse). See the README for details.
NOTES
)
fi
