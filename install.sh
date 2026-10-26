#!/bin/bash
# Installs the latest LilaMD release into /Applications (or ~/Applications if /Applications is not writable).
# Usage: curl -fsSL https://raw.githubusercontent.com/drkhwo/lilamd/main/install.sh | bash
set -euo pipefail

URL="https://github.com/drkhwo/lilamd/releases/latest/download/LilaMD.zip"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/LilaMD.zip"
ditto -x -k "$TMP/LilaMD.zip" "$TMP"

if pgrep -xq LilaMD; then
  echo "Quitting the running LilaMD"
  osascript -e 'tell application "LilaMD" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$DEST/LilaMD.app"
ditto "$TMP/LilaMD.app" "$DEST/LilaMD.app"
# The app is not notarized; curl does not quarantine downloads, but clear the flag in case it is set.
xattr -dr com.apple.quarantine "$DEST/LilaMD.app" 2>/dev/null || true

VERSION="$(defaults read "$DEST/LilaMD.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Installed LilaMD $VERSION to $DEST/LilaMD.app"
echo "Open it with: open -a LilaMD file.md"
