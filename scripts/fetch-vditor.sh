#!/bin/bash
# One-time download of the pinned Vditor dist into Resources/vditor (needs network only here).
set -euo pipefail
VERSION="3.11.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NPM="${NPM:-$HOME/.local/bin/npm}"
TMP="$(mktemp -d)"
cd "$TMP"
"$NPM" pack --silent "vditor@$VERSION" >/dev/null 2>&1
tar xzf "vditor-$VERSION.tgz"
rm -rf "$ROOT/Resources/vditor"
mkdir -p "$ROOT/Resources/vditor"
cp -R package/dist "$ROOT/Resources/vditor/dist"
cp package/LICENSE "$ROOT/Resources/vditor/LICENSE"
rm -rf "$ROOT/Resources/vditor/dist/ts" "$ROOT/Resources/vditor/dist/types" "$ROOT/Resources/vditor/dist/"*.d.ts
echo "$VERSION" > "$ROOT/Resources/vditor/VERSION"
rm -rf "$TMP"
echo "Vditor $VERSION -> $ROOT/Resources/vditor"
