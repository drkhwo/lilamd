#!/bin/bash
# FOREGROUND step 21: macOS conventions on screen (MAC-2 … MAC-7, MAC-10).
#   About panel screenshot and texts; window drag by the title bar and by the empty part of the tab strip; tab drag
#   reorders without moving the window; double click on the strip = double click on the title bar; Open Recent with a
#   deleted, a moved and a trashed file; Help items open the project pages in the default browser.
# Takes the screen, the focus, the mouse and the keyboard. Run only from the FOREGROUND.md batch.
# Uses the Debug build in build/dd; never touches /Applications/LilaMD.app.
# Open Recent needs real entries: the Debug app shares the bundle id (and the Open Recent list) with the installed app,
# so the step saves that list first and puts it back on exit.
# On exit: the Debug app quits, Open Recent list restored, browser tabs this step opened are closed, the front app comes back.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
E=/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0
OUT="$E/MAC/fg"
APP="$ROOT/build/dd/Build/Products/Debug/LilaMD.app"
BIN="$APP/Contents/MacOS/LilaMD"
WORK="$(mktemp -d /tmp/lilamd-macfg.XXXX)"
TOOL="$WORK/fgtool"
SFL_DIR="$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
SFL_BACKUP="$WORK/recents-backup"
FAILS=()

if pgrep -f "xcodebuild.*MDEditor" >/dev/null; then echo "RESULT 21-mac FAIL another xcodebuild is running"; exit 2; fi
rm -rf "$OUT" && mkdir -p "$OUT" "$SFL_BACKUP"
DRAG="$OUT/drag.txt"; RECENT="$OUT/recent.txt"; HELP="$OUT/help.txt"
: > "$DRAG"; : > "$RECENT"; : > "$HELP"

swiftc -O scripts/fg/fgtool.swift -o "$TOOL" > "$OUT/fgtool-build.log" 2>&1 || { echo "RESULT 21-mac FAIL fgtool did not build"; exit 1; }
FRONT_PID="$("$TOOL" frontmost)"
PID=""
# Open Recent of com.drkhwo.lilamd: save the files as they are (or note that there are none).
cp -p "$SFL_DIR"/com.drkhwo.lilamd.sfl* "$SFL_BACKUP"/ 2>/dev/null
ls "$SFL_BACKUP" > "$OUT/recents-before.txt"

quit_app() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  for _ in $(seq 1 30); do { [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; } && break; sleep 0.2; done
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  PID=""
}
restore_recents() {
  # The list lives in sharedfilelistd: stop it (it writes its state), then put the saved files back.
  killall sharedfilelistd 2>/dev/null; sleep 1
  rm -f "$SFL_DIR"/com.drkhwo.lilamd.sfl*
  cp -p "$SFL_BACKUP"/com.drkhwo.lilamd.sfl* "$SFL_DIR"/ 2>/dev/null
  ok=yes
  for f in "$SFL_BACKUP"/com.drkhwo.lilamd.sfl*; do [ -e "$f" ] || continue; cmp -s "$f" "$SFL_DIR/$(basename "$f")" || ok=no; done
  echo "recents restored: $ok" >> "$RECENT"
}
cleanup() {
  quit_app
  restore_recents
  rm -f "$HOME/.Trash/recent-trashed.md"
  [ -n "$FRONT_PID" ] && [ "$FRONT_PID" != "0" ] && "$TOOL" activate "$FRONT_PID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

xcodegen generate >/dev/null
if ! xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Debug -derivedDataPath build/dd build > "$OUT/build.log" 2>&1; then
  echo "RESULT 21-mac FAIL Debug build failed, see $OUT/build.log"; exit 1
fi

launch() {  # launch <records-recents YES|NO> [files…]
  quit_app
  local rec="$1"; shift
  open -n -a "$APP" "$@" --args -MDEditorRecordsRecents "$rec"
  for _ in $(seq 1 40); do PID="$(pgrep -n -f "$BIN" || true)"; [ -n "$PID" ] && break; sleep 0.25; done
  [ -n "$PID" ] || { FAILS+=("app did not start"); return 1; }
  sleep 3
  "$TOOL" activate "$PID" >/dev/null 2>&1
  sleep 0.5
}
frame() { "$TOOL" frame "$PID"; }
shoot_window() {  # shoot_window <file> <windowid>
  screencapture -x -o -l "$2" "$OUT/$1" 2>/dev/null || FAILS+=("$1: screencapture failed")
}
small_window() { "$TOOL" windows "$PID" | sort -k4 -n | head -1 | awk '{print $1}'; }   # About panel, alert
moved_by() {  # moved_by "<x y w h>" "<x y w h>" dx dy → yes|no (±3 pt)
  read -r ax ay _ _ <<< "$1"; read -r bx by _ _ <<< "$2"
  local ddx=$((bx - ax - $3)) ddy=$((by - ay - $4))
  [ ${ddx#-} -le 3 ] && [ ${ddy#-} -le 3 ] && echo yes || echo no
}

for n in alpha.md bravo.md charlie.md; do printf '# %s\n\nbody\n' "$n" > "$WORK/$n"; done

# --- MAC-2: About ---
launch NO "$WORK/alpha.md" "$WORK/bravo.md" "$WORK/charlie.md" || exit 1
"$TOOL" menu-items "$PID" LilaMD > "$OUT/app-menu.txt" 2>&1     # MAC-8 as AX sees it
[ "$(head -1 "$OUT/app-menu.txt")" = "-" ] && FAILS+=("MAC-8: separator at the top of the LilaMD menu")
awk 'p=="-" && $0=="-"{f=1} {p=$0} END{exit !f}' "$OUT/app-menu.txt" && FAILS+=("MAC-8: two separators in a row (AX)")
"$TOOL" menu "$PID" LilaMD "About LilaMD" || FAILS+=("About: menu item not pressed")
sleep 1.5
"$TOOL" texts "$PID" > "$OUT/about.txt"
shoot_window about.png "$(small_window)"
version="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info" MDEGitCommit))"
grep -qF "$version" "$OUT/about.txt" || FAILS+=("About: no \"$version\" in about.txt")
grep -qF "github.com/drkhwo/lilamd" "$OUT/about.txt" || echo "note: the link is not a static text in AX; check about.png" >> "$OUT/about.txt"
"$TOOL" key 13 cmd; sleep 0.5      # ⌘W in the About panel closes the panel (Close Tab → other key window)
[ "$("$TOOL" windows "$PID" | wc -l | tr -d ' ')" = "1" ] || FAILS+=("About: ⌘W did not close the panel")

# --- MAC-3: drag by the title bar ---
read -r wx wy ww wh <<< "$(frame)"
title_pt=""
for fx in 45 55 35 65 25; do      # an empty spot of the title bar / toolbar
  x=$((wx + ww * fx / 100)); y=$((wy + 12))
  role="$("$TOOL" hit $x $y | awk '{print $2}')"
  case "$role" in AXWindow|AXToolbar) title_pt="$x $y"; break;; esac
done
echo "title point: ${title_pt:-none} (role at it: ${role:-?})" >> "$DRAG"
if [ -n "$title_pt" ]; then
  read -r tx ty <<< "$title_pt"
  before="$(frame)"; "$TOOL" drag $tx $ty $((tx + 120)) $((ty + 60)); sleep 0.5; after="$(frame)"
  r="$(moved_by "$before" "$after" 120 60)"
  echo "MAC-3 title bar drag: before=[$before] after=[$after] moved=$r" >> "$DRAG"
  [ "$r" = yes ] || FAILS+=("MAC-3: title bar drag did not move the window")
  "$TOOL" drag $((tx + 120)) $((ty + 60)) $tx $ty; sleep 0.5
else
  FAILS+=("MAC-3: no empty title bar point found")
fi

# --- MAC-4: drag by the empty part of the tab strip ---
read -r wx wy ww wh <<< "$(frame)"
last="$("$TOOL" tabs "$PID" | tail -1)"
read -r _ _ lx ly lw lh <<< "$last"
sx=$((lx + lw + 60)); sy=$((ly + lh / 2))
echo "strip point: $sx $sy (last tab: $last; window: $wx $wy $ww $wh)" >> "$DRAG"
if [ $sx -lt $((wx + ww - 20)) ]; then
  before="$(frame)"; "$TOOL" drag $sx $sy $((sx + 120)) $((sy + 60)); sleep 0.5; after="$(frame)"
  r="$(moved_by "$before" "$after" 120 60)"
  echo "MAC-4 strip drag: before=[$before] after=[$after] moved=$r" >> "$DRAG"
  [ "$r" = yes ] || FAILS+=("MAC-4: strip drag did not move the window")
  "$TOOL" drag $((sx + 120)) $((sy + 60)) $sx $sy; sleep 0.5
else
  FAILS+=("MAC-4: no empty strip right of the tabs")
fi

# --- MAC-4: a tab drag reorders the tabs and leaves the window in place ---
order_before="$("$TOOL" tabs "$PID" | awk '{print $1}' | tr '\n' ' ')"
read -r _ _ ax ay aw ah <<< "$("$TOOL" tabs "$PID" | head -1)"
read -r _ _ cx cy cw ch <<< "$("$TOOL" tabs "$PID" | sed -n 3p)"
before="$(frame)"
"$TOOL" drag $((ax + aw / 2)) $((ay + ah / 2)) $((cx + cw / 2)) $((cy + ch / 2)); sleep 1
after="$(frame)"
order_after="$("$TOOL" tabs "$PID" | awk '{print $1}' | tr '\n' ' ')"
echo "MAC-4 tab drag: order [$order_before] → [$order_after]; frame [$before] → [$after]" >> "$DRAG"
[ "$order_before" != "$order_after" ] || FAILS+=("MAC-4: tab drag did not reorder")
[ "$before" = "$after" ] || FAILS+=("MAC-4: tab drag moved the window")
echo "MAC-4 drop of a .md file on the strip: not automated (needs a real drag session) — manual check by Stas" >> "$DRAG"

# --- MAC-5: double click on the strip = double click on the title bar ---
action="$(defaults read -g AppleActionOnDoubleClick 2>/dev/null || echo unset)"
echo "AppleActionOnDoubleClick=$action" >> "$DRAG"
if [ -n "$title_pt" ] && { [ "$action" = unset ] || [ "$action" = Maximize ]; }; then
  read -r tx ty <<< "$title_pt"
  f0="$(frame)"
  "$TOOL" click $tx $ty 2; sleep 1; f_title="$(frame)"
  "$TOOL" click $tx $ty 2; sleep 1; f_back="$(frame)"
  read -r _ _ lx ly lw lh <<< "$("$TOOL" tabs "$PID" | tail -1)"
  sx=$((lx + lw + 60)); sy=$((ly + lh / 2))
  "$TOOL" click $sx $sy 2; sleep 1; f_strip="$(frame)"
  read -r _ _ lx ly lw lh <<< "$("$TOOL" tabs "$PID" | tail -1)"
  "$TOOL" click $((lx + lw + 60)) $((ly + lh / 2)) 2; sleep 1
  echo "MAC-5: start=[$f0] title-dblclick=[$f_title] back=[$f_back] strip-dblclick=[$f_strip] end=[$(frame)]" >> "$DRAG"
  [ "$f_title" != "$f0" ] || FAILS+=("MAC-5: title bar double click changed nothing")
  [ "$f_strip" = "$f_title" ] || FAILS+=("MAC-5: strip double click ≠ title bar double click")
else
  echo "MAC-5: not checked (action=$action or no title point)" >> "$DRAG"
fi
quit_app

# --- MAC-6, MAC-7: Open Recent with a deleted, a moved and a trashed file ---
recent_case() {  # recent_case <name> <what to do with the file> <png>
  local name="$1" how="$2" png="$3" f="$WORK/$1"
  printf '# %s\n' "$name" > "$f"
  launch YES "$f" || return
  for _ in $(seq 1 20); do "$TOOL" tabs "$PID" | grep -q "^tab:$name " && break; sleep 0.25; done
  # The file goes away while the app runs with the entry in its Open Recent list. After a restart the system drops
  # entries of missing files by itself, so the menu would never offer the stale entry. The tab is closed first:
  # picking the entry of an open file only activates its tab.
  "$TOOL" menu "$PID" File "Close Tab"; sleep 1
  case "$how" in
    delete) rm -f "$f";;
    move) mkdir -p "$WORK/moved"; mv "$f" "$WORK/moved/$name";;
    trash) mv "$f" "$HOME/.Trash/$name";;
  esac
  "$TOOL" menu "$PID" File "Open Recent" "$name" || { echo "$name ($how): not in Open Recent" >> "$RECENT"; FAILS+=("Open Recent: $name missing"); return; }
  sleep 1.5
  "$TOOL" texts "$PID" > "$WORK/texts.txt"
  local tabs; tabs="$("$TOOL" tabs "$PID" 2>/dev/null | wc -l | tr -d ' ')"
  shoot_window "$png" "$(small_window)"
  local alive=yes; kill -0 "$PID" 2>/dev/null || alive=no
  { echo "== $name ($how): app alive=$alive, tabs=$tabs"; sed 's/^/  /' "$WORK/texts.txt"; } >> "$RECENT"
  [ "$alive" = yes ] || FAILS+=("Open Recent $how: the app died")
  "$TOOL" press "$PID" OK >/dev/null 2>&1; sleep 0.5
  [ "$(kill -0 "$PID" 2>/dev/null && echo yes)" = yes ] || FAILS+=("Open Recent $how: the app died after OK")
}
recent_case recent-deleted.md delete recent-deleted.png
grep -qF "The document “recent-deleted.md” could not be opened." "$RECENT" || FAILS+=("MAC-6: no alert text for the deleted file")
recent_case recent-moved.md move recent-moved.png
recent_case recent-trashed.md trash recent-trashed.png
echo "MAC-7: moved and trashed — behavior as recorded above (alert or tab), no crash required" >> "$RECENT"
quit_app

# --- MAC-10: Help items open the project pages ---
BROWSER="$("$TOOL" default-browser)"
echo "default browser: $BROWSER" >> "$HELP"
front_url() {
  case "$BROWSER" in
    com.google.Chrome) osascript -e 'tell application id "com.google.Chrome" to get URL of active tab of front window' 2>/dev/null;;
    com.apple.Safari) osascript -e 'tell application id "com.apple.Safari" to get URL of current tab of front window' 2>/dev/null;;
    *) echo "unknown-browser";;
  esac
}
close_front_tab() {
  case "$BROWSER" in
    com.google.Chrome) osascript -e 'tell application id "com.google.Chrome" to close active tab of front window' >/dev/null 2>&1;;
    com.apple.Safari) osascript -e 'tell application id "com.apple.Safari" to close current tab of front window' >/dev/null 2>&1;;
  esac
}
launch NO "$WORK/alpha.md" || exit 1
for pair in "LilaMD on GitHub|https://github.com/drkhwo/lilamd" "Report an Issue|https://github.com/drkhwo/lilamd/issues"; do
  item="${pair%%|*}"; want="${pair#*|}"
  "$TOOL" activate "$PID" >/dev/null 2>&1
  "$TOOL" menu "$PID" Help "$item" || { FAILS+=("Help: $item not pressed"); continue; }
  sleep 4
  got="$(front_url)"
  echo "$item → $got (want $want)" >> "$HELP"
  if [ "$got" = unknown-browser ]; then
    echo "  not checked: the URL of $BROWSER is not read by this step; look at the browser" >> "$HELP"
  elif [ "${got%/}" = "$want" ]; then
    close_front_tab
  else
    FAILS+=("MAC-10: $item opened [$got]")
  fi
done

if [ ${#FAILS[@]} -eq 0 ]; then
  echo "RESULT 21-mac PASS $OUT (about.png, recent-*.png, drag.txt, recent.txt, help.txt; the visual verdict is Stas's)"
  exit 0
fi
echo "RESULT 21-mac FAIL ${FAILS[*]}"
exit 1
