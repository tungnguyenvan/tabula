#!/usr/bin/env bash
# Renders the demo video to dist/demo/tabula-demo.mp4 with Remotion (demo/).
#
# The video shows Tabula driven by real input: recordings of a debug build (TABULA_DEBUG_RECORD, numbered JPEG
# frames plus events.json, the clicks and keys with their frames), made with TABULA_DEBUG_KEYS scripts whose
# click:x,y tokens post real mouse events to the window. The montage uses docs/screenshots. Recordings live in
# $RECORDINGS (default /tmp/tabula-rec); each was made with
#   TABULA_DATA_DIR=<test connections> TABULA_DEBUG_WIDTH=1300 TABULA_DEBUG_HEIGHT=760 (30 frames a second)
#   TABULA_DEBUG_RECORD=$RECORDINGS/<name> .build/debug/Tabula
# and:
#   chat     MongoDB, TABULA_DEBUG_AI_PROVIDER=claudeCode (start with no saved conversations), TABULA_DEBUG_KEYS=
#            "wait:3000;move:0.6,0.5;wait:300;click:0.947,0.034;wait:1200;click:0.8,0.948;wait:300;
#             slow:Which order status brings in the most revenue? Check the real data.;wait:300;return;wait:32000"
#   chatrun  MongoDB, right after chat (the conversation is restored): "wait:3000;click:0.947,0.034;wait:1500;
#            move:0.86,0.7;wait:500;click:0.843,0.814;wait:3000" (the answer's Run button; check where it is)
#   ask      PostgreSQL, claudeCode: "wait:3000;move:0.6,0.5;wait:400;click:0.428,0.124;wait:900;
#            slow:top 5 most expensive products with their price;wait:400;return;wait:24000;move:0.3,0.3;wait:300;
#            click:0.205,0.124;wait:3000"
#   inline   PostgreSQL, claudeCode, TABULA_DEBUG_AI_INLINE_PROVIDER=builtIn (a downloaded model):
#            "wait:4000;slow:SELECT name, price FROM products ORDER BY ;wait:9000;tab;wait:1500;cmd+return;wait:3000"
#   filter   PostgreSQL, TABULA_DEBUG_TABLE=products: "wait:3000;move:0.6,0.6;wait:300;click:0.357,0.979;wait:900;
#            click:0.932,0.129;wait:700;click:0.55,0.129;wait:300;slow:price >= 850;wait:400;return;wait:2500"
#   mongo    MongoDB, TABULA_DEBUG_TABLE=orders: "wait:3000;move:0.6,0.5;wait:300;click:0.45,0.156;wait:800;
#            click:0.3515,0.979;wait:3000"
# The model's answers differ between runs, so the `timeline` pairs in demo/src/Demo.tsx (which recorded frames
# show what) are checked against each new recording.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORDINGS="${RECORDINGS:-/tmp/tabula-rec}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-demo.mp4"

for name in chat chatrun ask inline filter mongo; do
  [ -f "$RECORDINGS/$name/frame-00001.jpg" ] || {
    echo "No $name recording in $RECORDINGS/$name (see the comment at the top of this script)." >&2; exit 1; }
done

rm -rf "$PUBLIC"
mkdir -p "$PUBLIC/shots" "$(dirname "$OUT")"
cp docs/screenshots/*.png "$PUBLIC/shots/"
sips -s format png Resources/AppIcon.icns --out "$PUBLIC/icon.png" >/dev/null
for name in chat chatrun ask inline filter mongo; do cp -R "$RECORDINGS/$name" "$PUBLIC/$name"; done
# Music and effects are synthesized, so the video has no third-party audio.
node demo/audio/make-audio.mjs "$PUBLIC/audio"

# Remotion's own headless Chrome fails to start in some setups (its helpers can't find their ICU data);
# the installed Google Chrome works, so it is used when present.
BROWSER="${BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_FLAG=()
[ -x "$BROWSER" ] && BROWSER_FLAG=(--browser-executable="$BROWSER")
(cd demo && npm ci --no-audit --no-fund && npx remotion render src/index.ts TabulaDemo "../$OUT" "${BROWSER_FLAG[@]}")
ls -lh "$OUT"
