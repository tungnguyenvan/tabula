#!/usr/bin/env bash
# Produces a release in dist/release/: Tabula-<version>.dmg, Tabula-<version>.zip, SHA256SUMS.txt, RELEASE_NOTES.md.
#
#   scripts/release.sh                     # tests, universal build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=tabula scripts/release.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials tabula --apple-id … --team-id … --password <app-specific password>
# Set SKIP_TESTS=1 to skip tests. Postgres/MySQL tests run when TABULA_TEST_PG_PORT / TABULA_TEST_MYSQL_PORT are set.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
OUT="dist/release"
APP="dist/Tabula.app"
NAME="Tabula-$VERSION"

step() { printf '\n==> %s\n' "$*"; }

grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  step "Tests"
  swift test
fi

step "Third-party notices"
scripts/third-party-notices.sh

step "Build"
scripts/build-app.sh

step "Verify"
lipo -info "$APP/Contents/MacOS/Tabula"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ]
# The shipped binary has no symbol table, so look for debug code in its symbols (dSYM).
if nm "dist/Tabula.app.dSYM/Contents/Resources/DWARF/Tabula" | grep -q DebugHooks; then
  echo "Release binary contains debug hooks" >&2; exit 1
fi

if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  step "Notarize"
  ditto -c -k --keepParent "$APP" "dist/notarize.zip"
  xcrun notarytool submit "dist/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "dist/notarize.zip"
  spctl --assess --type execute --verbose "$APP"
else
  echo "Not notarized (set SIGN_IDENTITY and NOTARY_PROFILE). Users must right-click → Open the first time."
fi

step "Package"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tabula $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT/$NAME.dmg" >/dev/null
if [ -n "${SIGN_IDENTITY:-}" ]; then codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/$NAME.dmg"; fi

# Release notes: this version's CHANGELOG section.
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {p=1; next} /^## \[/ {p=0} p' CHANGELOG.md > "$OUT/RELEASE_NOTES.md"

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
# Symbols for reading crash reports from this build; not part of the GitHub release.
ditto -c -k --keepParent "dist/Tabula.app.dSYM" "$OUT/$NAME.dSYM.zip"

step "Done"
ls -lh "$OUT"
cat "$OUT/SHA256SUMS.txt"
