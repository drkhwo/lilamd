#!/bin/bash
# Runs the XCTest suite.
#   scripts/test.sh                  background: no activation, windows off-screen; key-shortcut tests are skipped
#   scripts/test.sh --foreground     takes the screen; runs everything (needs an unlocked screen, hands off the keyboard)
# Extra arguments go to xcodebuild, e.g. -only-testing:MDEditorTests/TabStoreTests
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--foreground" ]; then
  shift
  export TEST_RUNNER_MDEDITOR_TEST_FOREGROUND=1
fi
xcodegen generate >/dev/null
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -derivedDataPath build/dd test "$@"
