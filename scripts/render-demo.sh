#!/usr/bin/env bash
# Renders the demo video to dist/demo/tabula-demo.mp4 with Remotion (demo/).
#
# The video uses the README screenshots (docs/screenshots) and recordings of a debug build, numbered JPEG frames
# made with TABULA_DEBUG_RECORD (see DebugHooks.swift), in $RECORDINGS (default /tmp/tabula-rec):
#
#   chat    the AI chat answering (10 fps):
#           TABULA_DEBUG_OPEN=<MongoDB connection> TABULA_DEBUG_AI_PROVIDER=claudeCode TABULA_DEBUG_RECORD=…/chat
#           TABULA_DEBUG_CHAT="Which order status brings in the most revenue? Check the real data and answer with a table."
#   inline  typing with AI suggestions, Tab to accept, ⌘↩ to run (15 fps):
#           TABULA_DEBUG_OPEN=<PostgreSQL connection> TABULA_DEBUG_AI_PROVIDER=claudeCode TABULA_DEBUG_AI_INLINE_PROVIDER=builtIn
#           TABULA_DEBUG_RECORD=…/inline TABULA_DEBUG_RECORD_FPS=15
#           TABULA_DEBUG_KEYS="wait:4000;slow:SELECT name, price FROM products ORDER BY ;wait:9000;tab;wait:1500;cmd+return;wait:3000"
#           (needs a model downloaded in Settings › AI; the first suggestion waits for it to load)
#   filter  a table being filtered (15 fps):
#           TABULA_DEBUG_OPEN=<PostgreSQL connection> TABULA_DEBUG_TABLE=products TABULA_DEBUG_FILTER="price|≥|850"
#           TABULA_DEBUG_FILTER_DELAY=3.5 TABULA_DEBUG_RECORD=…/filter TABULA_DEBUG_RECORD_FPS=15
#
# All with TABULA_DATA_DIR=<test connections> TABULA_DEBUG_WIDTH=1300 TABULA_DEBUG_HEIGHT=760 .build/debug/Tabula.
# The `timeline` pairs in demo/src/Demo.tsx say which recorded frames show what.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORDINGS="${RECORDINGS:-/tmp/tabula-rec}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-demo.mp4"

for name in chat inline filter; do
  [ -f "$RECORDINGS/$name/frame-00001.jpg" ] || {
    echo "No $name recording in $RECORDINGS/$name (see the comment at the top of this script)." >&2; exit 1; }
done

rm -rf "$PUBLIC"
mkdir -p "$PUBLIC/shots" "$(dirname "$OUT")"
cp docs/screenshots/*.png "$PUBLIC/shots/"
sips -s format png Resources/AppIcon.icns --out "$PUBLIC/icon.png" >/dev/null
for name in chat inline filter; do cp -R "$RECORDINGS/$name" "$PUBLIC/$name"; done

# Remotion's own headless Chrome fails to start in some setups (its helpers can't find their ICU data);
# the installed Google Chrome works, so it is used when present.
BROWSER="${BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_FLAG=()
[ -x "$BROWSER" ] && BROWSER_FLAG=(--browser-executable="$BROWSER")
(cd demo && npm ci --no-audit --no-fund && npx remotion render src/index.ts TabulaDemo "../$OUT" "${BROWSER_FLAG[@]}")
ls -lh "$OUT"
