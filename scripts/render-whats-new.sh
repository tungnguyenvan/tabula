#!/usr/bin/env bash
# Renders "What's new in 0.5.0–0.5.2" with Remotion (demo/src/WhatsNew.tsx): dist/demo/tabula-whats-new.mp4 (1080p,
# 60 fps) and dist/demo/tabula-whats-new-web.mp4 (under GitHub's 10 MB, for the README to play).
#
# Recordings of a debug build driven by real input, as for scripts/render-demo.sh, in $RECORDINGS (default
# /tmp/tabula-rec2). The pointer is drawn only around clicks. Each was made with scripts' TABULA_DEBUG_KEYS against
# the test connections (TABULA_DATA_DIR) at 30 frames a second, in a 1300×760 window unless noted:
#   tools       PostgreSQL (orders seeded, no saved conversations), TABULA_DEBUG_AI_PROVIDER=claudeCode:
#               "wait:3000;click:0.947,0.034;wait:1200;click:0.85,0.95;wait:300;slow:Revenue by status? Check the data.;
#                wait:300;return;wait:55000;click:0.986,0.144;wait:1000;click:0.85,0.95;wait:300;
#                slow:Top 3 products by price? Look it up.;wait:300;return;wait:40000" (the second saves a conversation)
#   history     PostgreSQL, claudeCode, reopened: "wait:3000;click:0.947,0.034;wait:1500;click:0.82,0.144;wait:1000;
#               down;wait:400;down;wait:500;return;wait:1500;click:0.779,0.266;wait:3000"
#   sidebar     PostgreSQL (with a view, functions and a trigger), no collapsed groups: "wait:3000;click:0.06,0.722;
#               wait:900;click:0.06,0.595;wait:900;click:0.06,0.469;wait:900;click:0.06,0.174;wait:1500;
#               click:0.06,0.174;wait:2000"
#   sqlfile     PostgreSQL: "wait:5000;open:<dir>/revenue_report.sql;wait:1500;cmd+up;down;down;cmd+right;wait:300;
#               slow: WHERE status <> 'refunded';wait:1200;click:0.513,0.126;wait:1500;cmd+return;wait:2500"
#   connstring  TABULA_DEBUG_TARGET=connections TABULA_DEBUG_VERSION=0.5.2, 1000×640: "wait:2500;click:0.1,0.94;
#               wait:1200;click:0.5,0.42;wait:800;paste:host=db.example.com dbname=shop user=app password=s3cret
#               sslmode=require;wait:2200;click:0.708,0.673;wait:3500"
# The model's answers differ between runs, so the `timeline` pairs in demo/src/WhatsNew.tsx are checked against
# each new recording.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORDINGS="${RECORDINGS:-/tmp/tabula-rec2}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-whats-new.mp4"
NAMES=(tools history sidebar sqlfile connstring)

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
(cd demo && npm ci --no-audit --no-fund && npx remotion render src/index.ts WhatsNew "../$OUT" "${BROWSER_FLAG[@]}" \
  && npx remotion render src/index.ts WhatsNew "../dist/demo/tabula-whats-new-web.mp4" --scale=0.75 --crf=27 "${BROWSER_FLAG[@]}")
ls -lh "$OUT" dist/demo/tabula-whats-new-web.mp4
