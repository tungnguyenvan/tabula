#!/usr/bin/env bash
# Renders "What's new in 0.5.0–0.5.4" with Remotion (demo/src/WhatsNew.tsx): dist/demo/tabula-whats-new.mp4 (1080p,
# 60 fps) and dist/demo/tabula-whats-new-web.mp4 (1440×810, under GitHub's 10 MB, for the README to play), both encoded
# from the same checked frames.
#
# Recordings of a debug build driven by real input, as for scripts/render-demo.sh, in $RECORDINGS (default
# /tmp/tabula-rec3). The pointer is drawn only around clicks. Each was made with scripts' TABULA_DEBUG_KEYS against
# the test connections (TABULA_DATA_DIR) at 30 frames a second, in a 1300×760 window unless noted:
#   tools       PostgreSQL (orders seeded, no saved conversations), TABULA_DEBUG_AI_PROVIDER=claudeCode:
#               "wait:3000;click:0.947,0.034;wait:1200;click:0.85,0.95;wait:300;slow:Revenue by status? Check the data.;
#                wait:300;return;wait:55000;click:0.986,0.144;wait:1000;click:0.85,0.95;wait:300;
#                slow:Top 3 products by price? Look it up.;wait:300;return;wait:40000" (the second saves a conversation)
#   history     PostgreSQL, claudeCode, reopened: "wait:3000;click:0.947,0.034;wait:1500;click:0.82,0.144;wait:1000;
#               down;wait:400;down;wait:500;return;wait:1500;click:0.779,0.266;wait:3000"
#   state       PostgreSQL with a real saved workspace: Query 3 (scratch SQL), orders (Data), monthly_revenue.sql,
#               customers (Structure). After closing and reopening the connection:
#               "wait:5000;call:closeconn;wait:1500;click:0.43,0.425;wait:2500;click:0.433,0.087;wait:1800;
#                click:0.61,0.087;wait:1800". The video starts at recorded frame 286 (the connection picker).
#   sidebar     PostgreSQL (with a view, functions and a trigger), no collapsed groups: "wait:3000;click:0.06,0.722;
#               wait:900;click:0.06,0.595;wait:900;click:0.06,0.469;wait:900;click:0.06,0.174;wait:1500;
#               click:0.06,0.174;wait:2000"
#   sqlfile     PostgreSQL: "wait:5000;open:<dir>/revenue_report.sql;wait:1500;cmd+up;down;down;cmd+right;wait:300;
#               slow: WHERE status <> 'refunded';wait:1200;click:0.513,0.126;wait:1500;cmd+return;wait:2500"
#   connstring  TABULA_DEBUG_TARGET=connections TABULA_DEBUG_VERSION=0.5.4, 1000×640: "wait:2500;click:0.1,0.94;
#               wait:1200;click:0.5,0.42;wait:800;paste:host=db.example.com dbname=shop user=app password=s3cret
#               sslmode=require;wait:2200;click:0.708,0.673;wait:3500"
# The model's answers differ between runs, so the `timeline` pairs in demo/src/WhatsNew.tsx are checked against
# each new recording.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORDINGS="${RECORDINGS:-/tmp/tabula-rec3}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-whats-new.mp4"
NAMES=(tools history state sidebar sqlfile connstring)

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
