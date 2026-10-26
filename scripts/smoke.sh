#!/bin/bash
# System smoke for LilaMD (TESTS.md section C, plus F1 through the real app).
# Usage: scripts/smoke.sh [output-dir]      (default: a new /tmp/mdeditor-smoke.XXXX)
# Works on copies of samples/ in <output-dir>/work; samples/ is never touched.
# Steps that need Accessibility (keystrokes via System Events) are reported "not verified" with the error.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d /tmp/mdeditor-smoke.XXXX)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/work"
rm -rf "$WORK" && mkdir -p "$WORK" && cp "$ROOT"/samples/* "$WORK"/
APP="/Applications/LilaMD.app"
BID="local.mdeditor.MDEditor"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

result() { printf '%-4s %-13s %s\n' "$1" "$2" "$3" | tee -a "$SUMMARY"; }
running() { pgrep -f "$APP/Contents/MacOS/LilaMD" >/dev/null; }
quit_app() {
  osascript -e "tell application id \"$BID\" to quit" >/dev/null 2>&1
  for _ in $(seq 1 50); do running || return 0; sleep 0.2; done
  pkill -f "$APP/Contents/MacOS/LilaMD"; sleep 1
}
open_doc() { open -a "$APP" "$@"; sleep "${WAIT:-4}"; }
front() { osascript -e "tell application id \"$BID\" to activate" >/dev/null 2>&1; open -a "$APP"; sleep 1.5; }
window_id() { swift "$ROOT/scripts/windowid.swift" "LilaMD" 2>/dev/null | head -1; }
shot() {  # shot <name>; retries while Stage Manager shows the window as a strip thumbnail
  local wid="" info w=0
  for _ in 1 2 3 4 5; do
    front
    osascript -e "tell application \"System Events\" to set frontmost of process \"LilaMD\" to true" >/dev/null 2>&1
    sleep 1.5
    info="$(window_id)"; wid="${info%% *}"
    if [ -n "$wid" ]; then screencapture -x -o -l"$wid" "$OUT/$1.png"; else screencapture -x "$OUT/$1.png"; fi
    w="$(sips -g pixelWidth "$OUT/$1.png" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    [ "${w:-0}" -gt 1000 ] && break
  done
  echo "$OUT/$1.png (${w:-?} px wide)"
}
keys() {  # keys <applescript body for System Events>; prints error text on failure
  osascript -e "tell application \"System Events\" to tell process \"LilaMD\"" -e "set frontmost to true" -e "$1" -e "end tell" 2>&1 >/dev/null
}
LOGPID=""
# shellcheck disable=SC2317
log_start() { log stream --level info --style compact --predicate 'subsystem == "local.mdeditor"' > "$OUT/$1.log" 2>&1 & LOGPID=$!; sleep 1.5; }
log_stop() { [ -n "$LOGPID" ] && { kill "$LOGPID" 2>/dev/null; wait "$LOGPID" 2>/dev/null; }; LOGPID=""; }

quit_app

# C1 — Release build + install
echo "== C1 build" >&2
(cd "$ROOT" && xcodegen generate --quiet && \
  xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Release -derivedDataPath build/release build) \
  > "$OUT/C1-build.log" 2>&1
BUILD=$?
if [ $BUILD -eq 0 ]; then
  rm -rf "$APP" && ditto "$ROOT/build/release/Build/Products/Release/LilaMD.app" "$APP"
fi
if [ $BUILD -eq 0 ] && [ -x "$APP/Contents/MacOS/LilaMD" ]; then
  result C1 pass "xcodebuild exit 0; installed $APP (version $(defaults read "$APP/Contents/Info" CFBundleShortVersionString), MDEGitCommit $(defaults read "$APP/Contents/Info" MDEGitCommit))"
else
  result C1 fail "xcodebuild exit $BUILD, see $OUT/C1-build.log"; exit 1
fi

# C2 — Launch Services registration
"$LSREGISTER" -f "$APP"
"$LSREGISTER" -dump > "$OUT/C2-lsregister.txt" 2>/dev/null
BLOCK="$(awk -v p="$APP" '/^-----/{ if (index(b, p) && index(b, "bundle")) print b; b=""; next } { b = b "\n" $0 } END { if (index(b, p)) print b }' "$OUT/C2-lsregister.txt")"
if printf '%s' "$BLOCK" | grep -q "net.daringfireball.markdown"; then
  result C2 pass "lsregister -dump: LilaMD bundle claims net.daringfireball.markdown (Editor role)"
else
  result C2 fail "net.daringfireball.markdown not in LilaMD's lsregister block ($OUT/C2-lsregister.txt)"
fi
DEFAULT="$(swift -e 'import AppKit; import UniformTypeIdentifiers; print(NSWorkspace.shared.urlForApplication(toOpen: UTType(importedAs: "net.daringfireball.markdown"))?.path ?? "none")' 2>/dev/null)"
echo "     info: current default app for .md: $DEFAULT" | tee -a "$SUMMARY"

# F1 — open, wait 5 s, quit: file untouched
F="$WORK/sample.md"
B_SHA="$(shasum -a 256 "$F" | cut -d' ' -f1)"; B_M="$(stat -f %m "$F")"
WAIT=5 open_doc "$F"; quit_app
A_SHA="$(shasum -a 256 "$F" | cut -d' ' -f1)"; A_M="$(stat -f %m "$F")"
if [ "$B_SHA" = "$A_SHA" ] && [ "$B_M" = "$A_M" ]; then
  result F1 pass "sha256 $A_SHA, mtime $A_M unchanged after open/5 s/quit"
else
  result F1 fail "before $B_SHA/$B_M after $A_SHA/$A_M"
fi

# C3 — visual mode screenshot
defaults write "$BID" editorMode visual
open_doc "$WORK/sample.md"
result C3 shot "$(shot C3-visual) (look: formatted headings/table/code)"

# C4 — Cmd+2 source mode
# Key codes, not characters: keystroke "2"/"s" depends on the active keyboard layout (e.g. Russian).
ERR="$(keys 'key code 19 using command down')"
sleep 1.5
if [ -z "$ERR" ]; then
  result C4 shot "$(shot C4-source) (look: plain monospaced markdown)"
  keys 'key code 18 using command down' >/dev/null; sleep 1
else
  result C4 "not verified" "System Events keystroke failed: $ERR"
fi

# C5 — type a line in Visual + Cmd+S
ERR="$(keys 'key code 125 using command down
delay 0.3
key code 36
delay 0.3
keystroke "5550125"
delay 1.2
key code 1 using command down')"
sleep 2
if [ -z "$ERR" ]; then
  # Digits only: they type the same in every keyboard layout.
  if tail -3 "$WORK/sample.md" | grep -q "5550125"; then
    result C5 pass "tail sample.md: $(tail -1 "$WORK/sample.md")"
  else
    result C5 fail "line not in file; tail: $(tail -2 "$WORK/sample.md" | tr '\n' '|')"
  fi
else
  result C5 "not verified" "System Events keystroke failed: $ERR"
fi
quit_app

# C6 — typing latency in big.md (from the app log)
log_start C6
WAIT=8 open_doc "$WORK/big.md"
# 20 digits at ~8 characters per second (a fast typist); a zero-delay burst would measure queueing.
ERR="$(keys 'key code 125
delay 3
repeat with c in characters of "12345678901234567890"
keystroke (c as text)
delay 0.12
end repeat')"
sleep 2; log_stop
if [ -z "$ERR" ]; then
  LAT="$(grep -o 'input latency [0-9.]*' "$OUT/C6.log" | awk '{print $3}')"
  N="$(printf '%s\n' "$LAT" | grep -c .)"
  MAX="$(printf '%s\n' "$LAT" | sort -n | tail -1)"
  MED="$(printf '%s\n' "$LAT" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
  if [ "$N" -ge 20 ] && awk -v m="$MAX" 'BEGIN{exit !(m < 100)}'; then
    result C6 pass "$N samples, median ${MED} ms, max ${MAX} ms ($OUT/C6.log)"
  else
    result C6 fail "$N samples, median ${MED:-?} ms, max ${MAX:-?} ms ($OUT/C6.log)"
  fi
else
  result C6 "not verified" "System Events keystroke failed: $ERR"
fi
quit_app

# C7 — file changed outside while the window is open (no unsaved edits)
log_start C7
open_doc "$WORK/crlf.md"
printf 'Line appended outside.\r\n' >> "$WORK/crlf.md"
sleep 3
result C7 shot "$(shot C7-external) (look: last line 'Line appended outside.')"
log_stop
quit_app
if grep -q "file changed on disk" "$OUT/C7.log" && grep -q "editor reloaded" "$OUT/C7.log" && \
   tail -1 "$WORK/crlf.md" | grep -q "Line appended outside."; then
  result C7 pass "log: change detected + editor reloaded; file keeps the external line after quit"
else
  result C7 fail "see $OUT/C7.log; tail: $(tail -1 "$WORK/crlf.md")"
fi

# C8 — dark appearance (app-level override; the system setting is not touched)
open -a "$APP" "$WORK/cyrillic.md" --args -MDEditorAppearance dark; sleep 4
result C8 shot "$(shot C8-dark) (look: dark editor)"
quit_app

echo "Summary: $SUMMARY" >&2
