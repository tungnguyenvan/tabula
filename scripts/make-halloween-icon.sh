#!/usr/bin/env bash
# Renders Resources/AppIcon-Halloween.icns: the Halloween icon drawn by Sources/Tabula/SeasonalIcon.swift, exported
# by a debug build (TABULA_DEBUG_SEASON_ICON) at 1024 px and scaled to every icon size.
# A release ships it as the app's icon with: APP_ICON=Resources/AppIcon-Halloween.icns scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift build --product Tabula
TABULA_DEBUG_SEASON_ICON="$WORK/icon.png" .build/debug/Tabula
mkdir "$WORK/AppIcon.iconset"
for base in 16 32 128 256 512; do
  sips -z "$base" "$base" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${base}x${base}.png" >/dev/null
  double=$((base * 2))
  sips -z "$double" "$double" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${base}x${base}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon-Halloween.icns
echo "Wrote Resources/AppIcon-Halloween.icns"
