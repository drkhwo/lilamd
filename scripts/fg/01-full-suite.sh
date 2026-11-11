#!/bin/bash
# FOREGROUND step 1: the full XCTest suite with the screen (key-shortcut tests included).
# Takes the screen and the keyboard. Run only from the FOREGROUND.md batch, never while the user works.
set -uo pipefail
cd "$(dirname "$0")/../.."
E=/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0
mkdir -p "$E/fg"
if pgrep -f "xcodebuild.*MDEditor" >/dev/null; then echo "RESULT 01-full-suite FAIL another xcodebuild is running"; exit 2; fi
scripts/test.sh --foreground > "$E/fg/test.log" 2>&1
code=$?
summary=$(grep -E "Executed [0-9]+ tests" "$E/fg/test.log" | tail -1 | sed 's/^[[:space:]]*//')
count=$(sed -E 's/.*Executed ([0-9]+) tests.*/\1/' <<< "$summary")
failures=$(sed -E 's/.* and ([0-9]+) failures.*/\1/' <<< "$summary")
if [ "$code" -eq 0 ] && [ "${failures:-1}" = "0" ] && [ "${count:-0}" -ge 146 ]; then
  echo "RESULT 01-full-suite PASS $summary"; exit 0
fi
echo "RESULT 01-full-suite FAIL exit=$code $summary"; exit 1
