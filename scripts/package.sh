#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release of LilaMD and packages it as
# dist/LilaMD.zip and dist/LilaMD.dmg (drag-to-Applications), plus SHA-256 sums.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DD="build/package"
APP="$DD/Build/Products/Release/LilaMD.app"
DIST="dist"

xcodegen generate >/dev/null
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Release -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build | grep -E "error:|\*\* BUILD" || true
lipo -info "$APP/Contents/MacOS/LilaMD"
codesign -v "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/LilaMD.zip"

STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/LilaMD.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LilaMD" -srcfolder "$STAGE" -ov -format UDZO "$DIST/LilaMD.dmg"
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 LilaMD.zip LilaMD.dmg > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "version $(defaults read "$ROOT/$APP/Contents/Info" CFBundleShortVersionString), commit $(defaults read "$ROOT/$APP/Contents/Info" MDEGitCommit)"
