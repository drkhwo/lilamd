#!/bin/bash
# FOREGROUND step 10: real-window screenshots of the active-tab highlight (TAB-4, TAB-5, TAB-7) and the real AX tree (TAB-3).
# Takes the screen, the focus and (for TAB-7) the keyboard. Run only from the FOREGROUND.md batch, never while the user works.
# Uses the Debug build in build/dd. Never touches /Applications/LilaMD.app. Restores the front app and quits the Debug app on exit.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
E=/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0
OUT="$E/TAB/fg"
APP="$ROOT/build/dd/Build/Products/Debug/LilaMD.app"
BIN="$APP/Contents/MacOS/LilaMD"
WORK="$(mktemp -d /tmp/lilamd-tabfg.XXXX)"
FAILS=()

if pgrep -f "xcodebuild.*MDEditor" >/dev/null; then echo "RESULT 10-tab-screenshots FAIL another xcodebuild is running"; exit 2; fi

FRONT_BID="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null || true)"
quit_app() { pkill -f "$BIN" 2>/dev/null; for _ in $(seq 1 30); do pgrep -f "$BIN" >/dev/null || return 0; sleep 0.2; done; }
cleanup() {
  quit_app
  rm -rf "$WORK"
  if [ -n "$FRONT_BID" ] && [ "$FRONT_BID" != "com.drkhwo.lilamd" ]; then open -b "$FRONT_BID" >/dev/null 2>&1; fi
}
trap cleanup EXIT

# Idempotent: clean the previous output of this step.
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate >/dev/null
if ! xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Debug -derivedDataPath build/dd build > "$OUT/build.log" 2>&1; then
  echo "RESULT 10-tab-screenshots FAIL Debug build failed, see $OUT/build.log"; exit 1
fi

# Files: names differ in length, one is long (truncation in the middle).
names=(alpha.md bravo.md charlie.md delta.md echo.md foxtrot.md golf-notes-with-a-very-long-file-name-for-truncation.md hotel.md india.md juliet.md)
for n in "${names[@]}"; do printf '# %s\n\nbody\n' "$n" > "$WORK/$n"; done

wid() { swift scripts/windowid.swift LilaMD 2>/dev/null | head -1 | awk '{print $1}'; }

# launch <appearance> <count>: fresh process with <count> tabs; the last opened file is the active tab.
launch() {
  quit_app
  local files=() i
  for ((i = 0; i < $2; i++)); do files+=("$WORK/${names[$i]}"); done
  open -n -a "$APP" --args -MDEditorAppearance "$1" -MDEditorRecordsRecents NO "${files[@]}"
  for _ in $(seq 1 40); do [ -n "$(wid)" ] && break; sleep 0.5; done
  sleep 2
}
activate_app() { open -a "$APP"; sleep 1.5; }
inactivate_app() { open -a Finder; sleep 1.5; }   # the app window stays on screen, but is not key
shoot() {  # shoot <file>
  local id; id="$(wid)"
  if [ -z "$id" ]; then FAILS+=("$1: no window"); return; fi
  screencapture -x -o -l "$id" "$OUT/$1"
  local w; w="$(sips -g pixelWidth "$OUT/$1" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  [ "${w:-0}" -gt 300 ] || FAILS+=("$1: ${w:-0} px wide")
}

# TAB-4: 3 tabs, 2 appearances, active and inactive window.
for ap in light dark; do
  launch "$ap" 3
  activate_app;   shoot "$ap-active.png"
  inactivate_app; shoot "$ap-inactive.png"
done

# TAB-5: 2 and 10 tabs, active window.
for ap in light dark; do
  for n in 2 10; do
    launch "$ap" "$n"; activate_app; shoot "tabs-$n-$ap.png"
  done
done

# TAB-3: the real AX tree. One selected tab, every tab has an identifier tab:<name>.
launch light 3; activate_app
osascript > "$OUT/ax-tabs.txt" 2>&1 <<'AS'
tell application "System Events" to tell process "LilaMD"
  set out to ""
  repeat with e in (entire contents of window 1)
    try
      set i to value of attribute "AXIdentifier" of e
      if i starts with "tab:" then set out to out & i & " selected=" & (value of attribute "AXSelected" of e) & linefeed
    end try
  end repeat
  return out
end tell
AS
sel=$(grep -c "selected=true" "$OUT/ax-tabs.txt" || true)
ids=$(grep -c "^tab:" "$OUT/ax-tabs.txt" || true)
{ [ "$sel" = "1" ] && [ "$ids" = "3" ]; } || FAILS+=("AX: $ids tab ids, $sel selected (see ax-tabs.txt; need 3 and 1)")

# TAB-7: 10 tabs, narrow window, Ctrl+Tab to the 10th tab: the strip must scroll so the active tab is visible.
launch light 10; activate_app
osascript -e 'tell application "System Events" to tell process "LilaMD" to set size of window 1 to {420, 500}' >/dev/null 2>&1
sleep 1
# The active tab after launch is the last one opened. Go to the first (Ctrl+Shift+Tab x9), then forward 9 times.
for _ in $(seq 1 9); do osascript -e 'tell application "System Events" to key code 48 using {control down, shift down}'; sleep 0.2; done
sleep 0.5; shoot "scroll-first.png"
for _ in $(seq 1 9); do osascript -e 'tell application "System Events" to key code 48 using control down'; sleep 0.2; done
sleep 1; shoot "scroll-to-active.png"

if [ ${#FAILS[@]} -eq 0 ]; then
  echo "RESULT 10-tab-screenshots PASS ${OUT} (10 PNG + ax-tabs.txt; the visual verdict is Stas's: look at the PNG files)"
  exit 0
fi
echo "RESULT 10-tab-screenshots FAIL ${FAILS[*]}"
exit 1
