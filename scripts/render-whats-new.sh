#!/usr/bin/env bash
# Renders "What's new in 0.6.0–0.7.0" with Remotion (demo/src/WhatsNew.tsx): dist/demo/tabula-whats-new.mp4 (1080p,
# 60 fps) and dist/demo/tabula-whats-new-web.mp4 (1440×810, under GitHub's 10 MB, for the README to play), both encoded
# from the same checked frames.
#
# Recordings of a debug build driven by real input, as for scripts/render-demo.sh, in $RECORDINGS (default
# /tmp/tabula-rec4). The pointer is drawn only around clicks. Each was made with TABULA_DEBUG_KEYS against the store
# from scripts/seed-dev.sh (TABULA_DATA_DIR; the MySQL connection tagged Development) at 30 frames a second, in a
# 1300×760 window unless noted, with TABULA_DEBUG_OPEN=<Test Postgres> unless noted:
#   ssh       TABULA_DEBUG_TARGET=connections TABULA_DEBUG_EDIT=<Test Postgres> TABULA_DEBUG_VERSION=0.7.0, 1000×640:
#             "wait:3000;move:0.7,0.8;wait:300;click:0.712,0.830;wait:1200;click:0.71,0.615;wait:500;tab;wait:800;
#              slow:bastion.example.com;wait:400;tab;wait:500;tab;wait:500;slow:deploy;wait:2500"
#   stop      "wait:3000;slow:SELECT pg_sleep(30);wait:600;cmd+return;wait:2500;move:0.25,0.2;wait:400;
#              click:0.229,0.125;wait:3000"
#   mysql     TABULA_DEBUG_OPEN=<Test MySQL>, employees reset to salary 2100 (id 2) and dept NULL (id 4):
#             "wait:3000;paste:SELECT id, name, dept, salary, hired FROM employees ORDER BY id;wait:500;cmd+return;
#              wait:1500;move:0.29,0.3;wait:300;click:0.29,0.342;wait:600;move:0.39,0.342;wait:300;dclick:0.3915,0.342;
#              wait:700;slow:2350;return;wait:800;move:0.3,0.398;wait:300;click:0.29,0.398;wait:600;move:0.334,0.398;
#              wait:300;dclick:0.334,0.398;wait:700;slow:Sales;return;wait:1200;move:0.45,0.95;wait:400;
#              click:0.4545,0.980;wait:3000"
#   tabs      "wait:3000;paste:SELECT id, customer_id, status, total FROM orders ORDER BY total DESC;wait:600;
#              cmd+return;wait:1500;move:0.45,0.38;wait:300;click:0.45,0.398;wait:1200;move:0.07,0.3;wait:300;
#              dclick:0.064,0.292;wait:1800;move:0.07,0.42;wait:300;dclick:0.06,0.42;wait:1800;move:0.28,0.09;
#              wait:300;click:0.283,0.086;wait:2500"
#   dump      TABULA_DEBUG_DUMP_TO=<dir>/shop.sql: "wait:3000;call:dump;wait:2500;move:0.62,0.70;wait:500;
#              click:0.660,0.737;wait:4500"
#   restore   That shop.sql into an empty database: TABULA_DEBUG_DATABASE=shop_copy TABULA_DEBUG_RESTORE_FROM=<dir>/shop.sql
#             "wait:3500;call:restore;wait:2500;move:0.62,0.70;wait:500;click:0.660,0.729;wait:6000"
# Each take starts with no saved workspace and an active window (the close button is red in the frames). The
# `timeline` pairs in demo/src/WhatsNew.tsx (which recorded frames show what) are checked against each new recording.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORDINGS="${RECORDINGS:-/tmp/tabula-rec4}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-whats-new.mp4"
NAMES=(ssh stop mysql tabs dump restore)

for name in "${NAMES[@]}"; do
  [ -f "$RECORDINGS/$name/frame-00001.jpg" ] || {
    echo "No $name recording in $RECORDINGS/$name (see the comment at the top of this script)." >&2; exit 1; }
done

rm -rf "$PUBLIC"
mkdir -p "$PUBLIC/whatsnew" "$(dirname "$OUT")"
sips -s format png Resources/AppIcon.icns --out "$PUBLIC/icon.png" >/dev/null
for name in "${NAMES[@]}"; do cp -R "$RECORDINGS/$name" "$PUBLIC/whatsnew/$name"; done
node demo/audio/make-audio.mjs "$PUBLIC/audio"

# As in render-demo.sh: the installed Google Chrome, when present, since Remotion's own headless Chrome may not start.
BROWSER="${BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_FLAG=()
[ -x "$BROWSER" ] && BROWSER_FLAG=(--browser-executable="$BROWSER")

# Frames are rendered as images first: now and then Chrome returns a screenshot of the wrong size, which shows in the
# video as the picture tiled. Broken frames are found (scripts/broken-frames.swift) and rendered again before encoding.
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT
(cd demo && npm ci --no-audit --no-fund \
  && npx remotion render src/index.ts WhatsNew "$FRAMES/frames" --sequence --image-format=jpeg --jpeg-quality=95 --concurrency=3 "${BROWSER_FLAG[@]}" \
  && npx remotion render src/index.ts WhatsNew "$FRAMES/audio.aac" --codec=aac "${BROWSER_FLAG[@]}")
for attempt in 1 2 3; do
  broken=$(swift scripts/broken-frames.swift "$FRAMES/frames" | awk '{print $1}')
  [ -z "$broken" ] && break
  for file in $broken; do
    frame=$((10#$(echo "$file" | tr -dc '0-9')))
    echo "Rendering broken frame $frame again"
    (cd demo && npx remotion still src/index.ts WhatsNew "$FRAMES/frames/$file" --frame="$frame" --image-format=jpeg --jpeg-quality=95 --log=error "${BROWSER_FLAG[@]}")
  done
done
[ -z "$(swift scripts/broken-frames.swift "$FRAMES/frames")" ] || { echo "Frames still broken after three attempts." >&2; exit 1; }

# Remotion names the frames element-0000.jpeg…; the pattern is read from the first one.
frames=("$FRAMES"/frames/*.jpeg)
first=$(basename "${frames[0]}")
digits=$(echo "$first" | tr -dc '0-9')
pattern="$FRAMES/frames/${first%%[0-9]*}%0${#digits}d.jpeg"
encode() { (cd demo && npx remotion ffmpeg -loglevel error -y -framerate 60 -start_number 0 -i "$pattern" -i "$FRAMES/audio.aac" \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -movflags +faststart -c:a copy -shortest "$@"); }
encode -crf 18 -preset slow "../$OUT"
encode -vf scale=1440:810 -crf 27 -preset slow "../dist/demo/tabula-whats-new-web.mp4"
ls -lh "$OUT" dist/demo/tabula-whats-new-web.mp4
