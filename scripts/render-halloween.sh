#!/usr/bin/env bash
# Renders the 5-second Halloween clip with Remotion (demo/src/HalloweenIcon.tsx): dist/demo/tabula-halloween.mp4
# (1080×1080, 60 fps). The regular icon comes from Resources/AppIcon.icns and the Halloween one from a debug build
# (TABULA_DEBUG_SEASON_ICON, the artwork in Sources/Tabula/SeasonalIcon.swift); the sound is synthesized by
# demo/audio/make-audio.mjs.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC="demo/public"
OUT="dist/demo/tabula-halloween.mp4"

swift build --product Tabula
rm -rf "$PUBLIC"
mkdir -p "$PUBLIC" "$(dirname "$OUT")"
sips -s format png Resources/AppIcon.icns --out "$PUBLIC/icon.png" >/dev/null
TABULA_DEBUG_SEASON_ICON="$PWD/$PUBLIC/halloween-icon.png" .build/debug/Tabula
node demo/audio/make-audio.mjs "$PUBLIC/audio"

# As in render-demo.sh: the installed Google Chrome, when present, since Remotion's own headless Chrome may not start.
BROWSER="${BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_FLAG=()
[ -x "$BROWSER" ] && BROWSER_FLAG=(--browser-executable="$BROWSER")
(cd demo && npx remotion render src/index.ts HalloweenIcon "../$OUT" --crf=18 "${BROWSER_FLAG[@]}")
ls -lh "$OUT"
