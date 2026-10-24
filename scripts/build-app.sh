#!/usr/bin/env bash
# Builds dist/Tabula.app (release configuration).
#
# Environment:
#   VERSION        marketing version (default: contents of ./VERSION)
#   BUILD_NUMBER   CFBundleVersion (default: UTC timestamp, always increasing)
#   ARCHS          "arm64 x86_64" (default, universal) or a single architecture
#   SIGN_IDENTITY  "Developer ID Application: …" to sign for distribution; ad-hoc when unset
#   COPYRIGHT      shown in Finder and the About panel
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
COPYRIGHT="${COPYRIGHT:-Copyright © 2026 Nguyen Van Tung. MIT License.}"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c release "${ARCH_FLAGS[@]}" --product Tabula
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Tabula"

APP="dist/Tabula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tabula"
cp Resources/AppIcon.icns Resources/Credits.html Resources/THIRD_PARTY_NOTICES.txt LICENSE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tabula</string>
    <key>CFBundleDisplayName</key><string>Tabula</string>
    <key>CFBundleIdentifier</key><string>app.tabula.Tabula</string>
    <key>CFBundleExecutable</key><string>Tabula</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSLocalNetworkUsageDescription</key><string>Tabula connects to the database servers you add, including ones on your local network.</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP $VERSION ($BUILD_NUMBER) for: $ARCHS"
