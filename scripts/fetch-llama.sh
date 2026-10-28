#!/usr/bin/env bash
# Downloads the pinned llama.cpp build (the engine Tabula uses to run local models) into
# Vendor/llama.xcframework, after checking its SHA-256. Run once after cloning; build-app.sh runs it too.
# The version is in LLAMA_CPP_VERSION: a release tag and the archive's SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r TAG SHA256 < LLAMA_CPP_VERSION
TARGET="Vendor/llama.xcframework"
STAMP="Vendor/.llama-$TAG"
if [ -d "$TARGET" ] && [ -f "$STAMP" ]; then exit 0; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA256  $work/llama.zip" | shasum -a 256 -c --status || { echo "llama.cpp $TAG: checksum mismatch" >&2; exit 1; }
unzip -q "$work/llama.zip" -d "$work/x"
rm -rf "$TARGET" Vendor/.llama-*
mkdir -p Vendor
mv "$work/x/build-apple/llama.xcframework" "$TARGET"
# Debug symbols are large and not shipped; drop them and the Info.plist entries that point at them.
find "$TARGET" -name dSYMs -type d -prune -exec rm -rf {} +
index=0
while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index" "$TARGET/Info.plist" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:$index:DebugSymbolsPath" "$TARGET/Info.plist" 2>/dev/null || true
  index=$((index + 1))
done
touch "$STAMP"
echo "llama.cpp $TAG → $TARGET"
