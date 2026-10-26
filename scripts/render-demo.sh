#!/usr/bin/env bash
# Renders the demo video to dist/demo/tabula-demo.mp4 with Remotion (demo/).
#
# The video uses the README screenshots (docs/screenshots) and a recording of the AI chat: numbered JPEG frames
# from a debug build, made with TABULA_DEBUG_RECORD (see DebugHooks.swift), for example:
#
#   TABULA_DATA_DIR=… TABULA_DEBUG_OPEN=<MongoDB connection id> TABULA_DEBUG_AI_PROVIDER=claudeCode \
#   TABULA_DEBUG_WIDTH=1300 TABULA_DEBUG_HEIGHT=760 TABULA_DEBUG_RECORD=/tmp/tabula-rec/chat \
#   TABULA_DEBUG_CHAT="Which order status brings in the most revenue? Check the real data and answer with a table." \
#   .build/debug/Tabula
#
# CHAT_FRAMES points at those frames (default /tmp/tabula-rec/chat). The scene timings in demo/src/Demo.tsx
# (`recorded`) say which frames show the question, the tool step and the finished answer.
set -euo pipefail
cd "$(dirname "$0")/.."

CHAT_FRAMES="${CHAT_FRAMES:-/tmp/tabula-rec/chat}"
LAST_FRAME="${LAST_FRAME:-204}"
PUBLIC="demo/public"
OUT="dist/demo/tabula-demo.mp4"

[ -f "$CHAT_FRAMES/frame-$(printf %05d "$LAST_FRAME").jpg" ] || {
  echo "No chat recording in $CHAT_FRAMES (see the comment at the top of this script)." >&2; exit 1; }

rm -rf "$PUBLIC"
mkdir -p "$PUBLIC/shots" "$PUBLIC/chat" "$(dirname "$OUT")"
cp docs/screenshots/*.png "$PUBLIC/shots/"
sips -s format png Resources/AppIcon.icns --out "$PUBLIC/icon.png" >/dev/null
for n in $(seq 1 "$LAST_FRAME"); do
  cp "$CHAT_FRAMES/frame-$(printf %05d "$n").jpg" "$PUBLIC/chat/"
done

# Remotion's own headless Chrome fails to start in some setups (its helpers can't find their ICU data);
# the installed Google Chrome works, so it is used when present.
BROWSER="${BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_FLAG=()
[ -x "$BROWSER" ] && BROWSER_FLAG=(--browser-executable="$BROWSER")
(cd demo && npm ci --no-audit --no-fund && npx remotion render src/index.ts TabulaDemo "../$OUT" "${BROWSER_FLAG[@]}")
ls -lh "$OUT"
