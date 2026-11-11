#!/bin/bash
# FOREGROUND step 20: Close Tab on screen, 100 counted runs (CLOSE-4, CLOSE-5).
#   scripts/fg/20-close-100.sh            ⌘W (CGEvent) and File ▸ Close Tab (AX press), alternating → E/CLOSE/fg/
#   scripts/fg/20-close-100.sh cmdw       ⌘W only, 100 counted runs → E/CLOSE/fg-cmdw/
# Each run: click into the editor, ⌘↓, type a marker, pause 0.3 s or 2.0 s (alternating), then close. Checks: the tab "tab:<name>" is gone from the AX tree and the file has the marker.
# Takes the screen, the focus, the mouse, the keyboard and the input source (U.S. for ⌘W). Run only from the
# FOREGROUND.md batch. Uses the Debug build in build/dd; never touches /Applications/LilaMD.app.
# On exit: the Debug app quits, the input source and the front app come back, log stream stops, temp files go.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
E=/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0
MODE="${1:-alternate}"
case "$MODE" in alternate) OUT="$E/CLOSE/fg";; cmdw) OUT="$E/CLOSE/fg-cmdw";; *) echo "usage: $0 [alternate|cmdw]"; exit 2;; esac
APP="$ROOT/build/dd/Build/Products/Debug/LilaMD.app"
BIN="$APP/Contents/MacOS/LilaMD"
WORK="$(mktemp -d /tmp/lilamd-closefg.XXXX)"
TOOL="$WORK/fgtool"
TARGET=100
FILES=140          # spare tabs for runs that do not count
MAX_SKIPPED=30
US_SOURCE=com.apple.keylayout.US

if pgrep -f "xcodebuild.*MDEditor" >/dev/null; then echo "RESULT 20-close-100-$MODE FAIL another xcodebuild is running"; exit 2; fi

rm -rf "$OUT" && mkdir -p "$OUT/shots"
RUN="$OUT/run.txt"
: > "$RUN"
say() { echo "$*" | tee -a "$RUN"; }

swiftc -O scripts/fg/fgtool.swift -o "$TOOL" > "$OUT/fgtool-build.log" 2>&1 || { echo "RESULT 20-close-100-$MODE FAIL fgtool did not build"; exit 1; }

FRONT_PID="$("$TOOL" frontmost)"
SOURCE_BEFORE="$("$TOOL" source-get)"
echo "$SOURCE_BEFORE" > "$OUT/source-before.txt"
PID=""
LOGPID=""
quit_app() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  for _ in $(seq 1 30); do { [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; } && return 0; sleep 0.2; done
  kill -9 "$PID" 2>/dev/null
}
cleanup() {
  quit_app
  [ -n "$LOGPID" ] && kill "$LOGPID" 2>/dev/null
  "$TOOL" source-set "$SOURCE_BEFORE" 2>/dev/null
  "$TOOL" source-get > "$OUT/source-after.txt" 2>/dev/null
  [ -n "$FRONT_PID" ] && [ "$FRONT_PID" != "0" ] && "$TOOL" activate "$FRONT_PID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

xcodegen generate >/dev/null
if ! xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Debug -derivedDataPath build/dd build > "$OUT/build.log" 2>&1; then
  echo "RESULT 20-close-100-$MODE FAIL Debug build failed, see $OUT/build.log"; exit 1
fi

# ⌘W by key code needs a Latin layout; typing goes as Unicode and does not depend on it.
"$TOOL" source-set "$US_SOURCE" || { echo "RESULT 20-close-100-$MODE FAIL input source $US_SOURCE not enabled"; exit 1; }

files=()
for i in $(seq -f "%03g" 1 $FILES); do printf 'Line of c%s.md\n' "$i" > "$WORK/c$i.md"; files+=("$WORK/c$i.md"); done

log stream --style compact --level info --predicate 'subsystem == "com.drkhwo.lilamd"' > "$OUT/stream.log" 2>&1 &
LOGPID=$!
sleep 1

open -n -a "$APP" --args -MDEditorRecordsRecents NO "${files[@]}"
for _ in $(seq 1 40); do PID="$(pgrep -n -f "$BIN" || true)"; [ -n "$PID" ] && break; sleep 0.25; done
[ -n "$PID" ] || { echo "RESULT 20-close-100-$MODE FAIL Debug app did not start"; exit 1; }
for _ in $(seq 1 60); do [ "$("$TOOL" tabs "$PID" 2>/dev/null | wc -l)" -ge "$FILES" ] && break; sleep 0.5; done
n="$("$TOOL" tabs "$PID" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -ge "$FILES" ] || { echo "RESULT 20-close-100-$MODE FAIL $n tabs in AX, need $FILES (Accessibility permission for this terminal?)"; exit 1; }
sleep 2

shot() {  # shot <file>
  local id; id="$("$TOOL" windows "$PID" | sort -k4 -n -r | head -1 | awk '{print $1}')"
  [ -n "$id" ] && screencapture -x -o -l "$id" "$OUT/shots/$1" 2>/dev/null
}
tab_open() { "$TOOL" tabs "$PID" | grep -q "^tab:$1 "; }

pass=0; fail=0; skipped=0; run=0
while [ $((pass + fail)) -lt $TARGET ]; do
  run=$((run + 1))
  if [ $skipped -gt $MAX_SKIPPED ]; then say "stop: more than $MAX_SKIPPED runs did not count"; break; fi
  name="$("$TOOL" tabs "$PID" | awk '/selected=true/{sub(/^tab:/, "", $1); print $1; exit}')"
  if [ -z "$name" ]; then say "stop: no active tab left"; break; fi
  file="$WORK/$name"
  if [ "$MODE" = cmdw ] || [ $((run % 2)) -eq 1 ]; then how=cmdW; else how=menu; fi
  if [ $(((run / 2) % 2)) -eq 0 ]; then pause=0.3; else pause=2.0; fi
  marker=" e$run"
  if ! "$TOOL" activate "$PID" 2>/dev/null; then
    skipped=$((skipped + 1)); say "run $run $name SKIP app not frontmost"; continue
  fi
  read -r wx wy ww wh <<< "$("$TOOL" frame "$PID")"
  "$TOOL" click $((wx + ww / 2)) $((wy + wh * 6 / 10))
  sleep 0.2
  "$TOOL" key 125 cmd          # ⌘↓: end of the document
  sleep 0.2
  "$TOOL" type "$marker"
  edited=unknown
  for _ in $(seq 1 10); do edited="$("$TOOL" edited "$PID")"; [ "$edited" = "true" ] && break; sleep 0.1; done
  shot "run$run-before.png"
  if [ "$edited" = "false" ]; then
    # The keys did not reach the editor (focus elsewhere): the run does not count. Close the clean tab and go on.
    skipped=$((skipped + 1)); say "run $run $name SKIP edit did not reach the editor (window not edited)"
    "$TOOL" menu "$PID" File "Close Tab"; sleep 0.5; continue
  fi
  sleep "$pause"
  "$TOOL" activate "$PID" 2>/dev/null
  if [ "$how" = cmdW ]; then "$TOOL" key 13 cmd; else "$TOOL" menu "$PID" File "Close Tab"; fi
  gone=no
  for _ in $(seq 1 50); do tab_open "$name" || { gone=yes; break; }; sleep 0.1; done
  has=no; grep -qF -- "$marker" "$file" && has=yes
  sha="$(shasum -a 256 "$file" | cut -c1-12)"
  if [ $gone = yes ] && [ $has = yes ]; then
    pass=$((pass + 1)); say "run $run $name $how pause=$pause PASS sha=$sha"
    rm -f "$OUT/shots/run$run-before.png"
  else
    fail=$((fail + 1)); shot "run$run-after.png"
    say "run $run $name $how pause=$pause FAIL tab_gone=$gone file_has_edit=$has edited=$edited sha=$sha"
    if [ $gone = no ]; then "$TOOL" menu "$PID" File "Close Tab"; sleep 1; tab_open "$name" && { say "stop: $name does not close"; break; }; fi
  fi
done

sleep 1
closeTab_lines=$(grep -c "closeTab: keyWindow=" "$OUT/stream.log" || true)
close_end=$(grep -c "TabStore.close end" "$OUT/stream.log" || true)
flush_lines=$(grep -c "flushEditor:" "$OUT/stream.log" || true)
say "log: closeTab=$closeTab_lines TabStore.close end=$close_end flushEditor=$flush_lines"
counted=$((pass + fail))
say "RESULT 20-close-100-$MODE pass=$pass fail=$fail skipped=$skipped counted=$counted"
if [ $fail -eq 0 ] && [ $pass -ge $TARGET ] && [ "$closeTab_lines" -gt 0 ] && [ "$close_end" -gt 0 ]; then
  echo "RESULT 20-close-100-$MODE PASS pass=$pass fail=0 skipped=$skipped ($RUN)"; exit 0
fi
echo "RESULT 20-close-100-$MODE FAIL pass=$pass fail=$fail skipped=$skipped ($RUN)"; exit 1
