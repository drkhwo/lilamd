#!/bin/bash
# FOREGROUND step 30: live typing with real input sources (IME-7, IME-8, IME-9).
#   scripts/fg/30-ime-live.sh                       sources that are enabled now; the others are reported and skipped
#   ENABLE_MISSING=1 scripts/fg/30-ime-live.sh      also enables the sources the system knows but the user has not enabled
#                                                   (Pinyin – Simplified, Japanese Kana); they are disabled again on exit.
#                                                   Installs nothing: a source the system does not know is only reported.
# Sources: Russian – PC (RussianWin, direct), Pinyin – Simplified (marked text, candidate by Space), Japanese Kana (marked text, Return).
# Places: paragraph, heading, table cell, list item (the target block is the last one in the file; the caret goes there with ⌘↓), first line of an empty file.
# Takes the screen, the focus, the keyboard and the input source. Run only from the FOREGROUND.md batch, never while the user works.
# Uses the Debug build in build/dd; never touches /Applications/LilaMD.app. Needs Accessibility for the terminal (CGEvent, AX).
# On exit (trap): the Debug app quits, sources enabled by this step are disabled, the original source is selected again,
# `sources-before.txt` is compared with `sources-after.txt`, the front app comes back, temp files go.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
E=/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0
OUT="$E/IME/fg"
APP="$ROOT/build/dd/Build/Products/Debug/LilaMD.app"
BIN="$APP/Contents/MacOS/LilaMD"
WORK="$(mktemp -d /tmp/lilamd-imefg.XXXX)"
FGTOOL="$WORK/fgtool"
IMETOOL="$WORK/imetool"
AUTOSAVE_WAIT=3.5   # the app autosaves 2 s after the last edit
STEP=0.15           # pause between keys, like a person

if pgrep -f "xcodebuild.*MDEditor" >/dev/null; then echo "RESULT 30-ime-live FAIL another xcodebuild is running"; exit 2; fi
rm -rf "$OUT" && mkdir -p "$OUT/shots" "$OUT/files"
RUN="$OUT/run.txt"; : > "$RUN"
say() { echo "$*" | tee -a "$RUN"; }

swiftc -O scripts/fg/fgtool.swift -o "$FGTOOL" > "$OUT/fgtool-build.log" 2>&1 || { echo "RESULT 30-ime-live FAIL fgtool did not build"; exit 1; }
swiftc -O scripts/fg/30-ime-live.swift -o "$IMETOOL" > "$OUT/imetool-build.log" 2>&1 || { echo "RESULT 30-ime-live FAIL imetool did not build"; exit 1; }

# State before: enabled sources and the current one (IME-8).
"$IMETOOL" enabled > "$OUT/sources-before.txt"
SOURCE_BEFORE="$("$IMETOOL" current)"
echo "current: $SOURCE_BEFORE" >> "$OUT/sources-before.txt"
"$IMETOOL" list > "$OUT/sources-known.txt"
FRONT_PID="$("$FGTOOL" frontmost)"
PID=""
ENABLED_BY_US=()
RESTORED=unknown

quit_app() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  for _ in $(seq 1 30); do { [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; } && return 0; sleep 0.2; done
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  return 0
}
cleanup() {
  quit_app
  for id in "${ENABLED_BY_US[@]:-}"; do [ -n "$id" ] && "$IMETOOL" disable "$id" 2>/dev/null; done
  "$IMETOOL" select "$SOURCE_BEFORE" 2>/dev/null
  sleep 0.5
  "$IMETOOL" enabled > "$OUT/sources-after.txt" 2>/dev/null
  echo "current: $("$IMETOOL" current 2>/dev/null)" >> "$OUT/sources-after.txt"
  if cmp -s "$OUT/sources-before.txt" "$OUT/sources-after.txt"; then RESTORED=yes; else RESTORED=no; fi
  echo "sources restored: $RESTORED" >> "$RUN"
  [ -n "$FRONT_PID" ] && [ "$FRONT_PID" != "0" ] && "$FGTOOL" activate "$FRONT_PID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

xcodegen generate >/dev/null
if ! xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Debug -derivedDataPath build/dd build > "$OUT/build.log" 2>&1; then
  echo "RESULT 30-ime-live FAIL Debug build failed, see $OUT/build.log"; exit 1
fi

wait_source() {  # wait_source <id>: the current source is <id> within 3 s
  for _ in $(seq 1 30); do [ "$("$IMETOOL" current)" = "$1" ] && return 0; sleep 0.1; done
  return 1
}
keys() {  # keys <code>…: one key per step, no modifiers
  for c in "$@"; do "$FGTOOL" key "$c"; sleep "$STEP"; done
}

# Sources: name | id | key codes | key after the keys (Space 49 / Return 36 / none) | expected text
# Key codes (ANSI): Russian PC п р и в е т = G H B D T N; Pinyin "nihao" = N I H A O; Kana こ ん に ち は = B Y I A F.
declare -a S_NAME=(RussianWin Pinyin Kana)
declare -a S_ID=(com.apple.keylayout.RussianWin com.apple.inputmethod.SCIM.ITABC com.apple.inputmethod.Kotoeri.KanaTyping.Japanese)
declare -a S_KEYS=("5 4 11 2 17 45" "45 34 4 0 31" "11 16 34 0 3")
declare -a S_COMMIT=("" 49 36)
declare -a S_EXPECT=("привет" "你好" "こんにちは")

# Places: name | file content (the target block is last). The typed text must appear once, at the end of that block.
declare -a P_NAME=(paragraph heading table list first-line)
declare -a P_DOC=("Intro\n\nlast paragraph\n" "Intro\n\n# last heading\n" "Intro\n\n| a | b |\n| --- | --- |\n| c | d |\n" "Intro\n\n- one\n- last item\n" "")

pass=0; fail=0; skipped=0
say "IME live run $(date '+%F %T'); original source: $SOURCE_BEFORE; ENABLE_MISSING=${ENABLE_MISSING:-0}"

for si in "${!S_NAME[@]}"; do
  name="${S_NAME[$si]}"; id="${S_ID[$si]}"; expect="${S_EXPECT[$si]}"
  if [ "$("$IMETOOL" is-enabled "$id")" != yes ]; then
    if [ "$("$IMETOOL" exists "$id")" != yes ]; then
      skipped=$((skipped + 5)); say "SKIP $name: the system does not know $id (nothing is installed by this step)"; continue
    fi
    if [ "${ENABLE_MISSING:-0}" = 1 ]; then
      if "$IMETOOL" enable "$id"; then ENABLED_BY_US+=("$id"); say "$name: enabled for this run, disabled again on exit"; else
        skipped=$((skipped + 5)); say "SKIP $name: the system refused to enable $id"; continue
      fi
    else
      skipped=$((skipped + 5)); say "SKIP $name: $id is not enabled (run with ENABLE_MISSING=1 to enable it for the run)"; continue
    fi
  fi
  for pi in "${!P_NAME[@]}"; do
    place="${P_NAME[$pi]}"
    f="$WORK/${name}-${place}.md"
    printf "${P_DOC[$pi]}" > "$f"
    cp "$f" "$OUT/files/${name}-${place}.before.md"
    quit_app; PID=""
    "$IMETOOL" select com.apple.keylayout.US 2>/dev/null   # the window opens in a neutral source; ⌘↓ does not depend on it
    open -n -a "$APP" "$f" --args -MDEditorRecordsRecents NO
    for _ in $(seq 1 40); do PID="$(pgrep -n -f "$BIN" || true)"; [ -n "$PID" ] && break; sleep 0.25; done
    if [ -z "$PID" ]; then fail=$((fail + 1)); say "FAIL $name/$place: Debug app did not start"; continue; fi
    for _ in $(seq 1 40); do [ "$("$FGTOOL" tabs "$PID" 2>/dev/null | wc -l)" -ge 1 ] && break; sleep 0.5; done
    sleep 2
    if ! "$FGTOOL" activate "$PID" 2>/dev/null; then skipped=$((skipped + 1)); say "SKIP $name/$place: app not frontmost"; continue; fi
    "$FGTOOL" key 125 cmd; sleep 0.3                      # ⌘↓: caret at the end of the document
    if ! "$IMETOOL" select "$id" || ! wait_source "$id"; then
      fail=$((fail + 1)); say "FAIL $name/$place: could not select $id (current: $("$IMETOOL" current))"; continue
    fi
    keys ${S_KEYS[$si]}
    sleep 0.5
    "$FGTOOL" windows "$PID" | sort -k4 -n -r | head -1 | awk '{print $1}' | { read -r wid; [ -n "$wid" ] && screencapture -x -o -l "$wid" "$OUT/shots/${name}-${place}-marked.png"; }
    if [ -n "${S_COMMIT[$si]}" ]; then "$FGTOOL" key "${S_COMMIT[$si]}"; sleep 0.4; fi
    "$IMETOOL" select com.apple.keylayout.US 2>/dev/null; wait_source com.apple.keylayout.US
    "$FGTOOL" windows "$PID" | sort -k4 -n -r | head -1 | awk '{print $1}' | { read -r wid; [ -n "$wid" ] && screencapture -x -o -l "$wid" "$OUT/shots/${name}-${place}-committed.png"; }
    sleep "$AUTOSAVE_WAIT"
    cp "$f" "$OUT/files/${name}-${place}.after.md"
    count="$(grep -oF -- "$expect" "$f" | wc -l | tr -d ' ')"
    # With the typed text removed the file must be the original (trailing newlines ignored): nothing lost, nothing doubled.
    stripped="$(python3 -I - "$f" "$expect" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read().replace(sys.argv[2], "", 1)
print(t.rstrip("\n"), end="")
PY
)"
    original="$(python3 -I - "$OUT/files/${name}-${place}.before.md" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().rstrip("\n"), end="")
PY
)"
    if [ "$count" = 1 ] && [ "$stripped" = "$original" ]; then
      pass=$((pass + 1)); say "PASS $name/$place: \"$expect\" once, the rest of the file unchanged"
    else
      fail=$((fail + 1)); say "FAIL $name/$place: \"$expect\" found $count times; rest unchanged: $([ "$stripped" = "$original" ] && echo yes || echo no); file: $(head -c 300 "$f" | tr '\n' '|')"
    fi
  done
done

# IME-9 (S): press-and-hold on U.S. Hold "e", pick the first accent. Synthetic events may not open the picker: then the result is inconclusive, not a fail.
quit_app; PID=""
f="$WORK/hold.md"; printf 'Intro\n\nlast paragraph\n' > "$f"; cp "$f" "$OUT/files/hold.before.md"
"$IMETOOL" select com.apple.keylayout.US 2>/dev/null; wait_source com.apple.keylayout.US
open -n -a "$APP" "$f" --args -MDEditorRecordsRecents NO
for _ in $(seq 1 40); do PID="$(pgrep -n -f "$BIN" || true)"; [ -n "$PID" ] && break; sleep 0.25; done
if [ -n "$PID" ]; then
  sleep 3; "$FGTOOL" activate "$PID" 2>/dev/null
  "$FGTOOL" key 125 cmd; sleep 0.3
  "$IMETOOL" hold 14 1.2 18   # key e, wait 1.2 s, pick "1" (first accent)
  sleep "$AUTOSAVE_WAIT"; cp "$f" "$OUT/files/hold.after.md"
  accent="$(grep -o 'é\|è\|ê\|ë\|ē\|ė\|ę' "$f" | wc -l | tr -d ' ')"
  plain="$(grep -c 'last paragraphe' "$f" || true)"
  doubled="$(grep -cE 'paragraph(ee|éé|ée|eé)' "$f" || true)"
  if [ "$doubled" != 0 ]; then fail=$((fail + 1)); say "FAIL IME-9 press-and-hold: doubled characters: $(tail -c 60 "$f" | tr '\n' '|')"
  elif [ "$accent" = 1 ]; then pass=$((pass + 1)); say "PASS IME-9 press-and-hold: one accented letter"
  else skipped=$((skipped + 1)); say "INCONCLUSIVE IME-9 press-and-hold: the synthetic hold did not open the picker (plain e: $plain). Check by hand: hold e in LilaMD on U.S."; fi
else
  skipped=$((skipped + 1)); say "SKIP IME-9: Debug app did not start"
fi

quit_app; PID=""
say "RESULT 30-ime-live pass=$pass fail=$fail skipped=$skipped"
# The verdict on sources comes after the trap runs; the line `sources restored: yes|no` is appended to run.txt then.
if [ $fail -eq 0 ] && [ $pass -gt 0 ]; then echo "RESULT 30-ime-live PASS pass=$pass fail=0 skipped=$skipped ($RUN; check the line 'sources restored' after exit)"; exit 0; fi
echo "RESULT 30-ime-live FAIL pass=$pass fail=$fail skipped=$skipped ($RUN)"; exit 1
