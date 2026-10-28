#!/usr/bin/env bash
# Updates the public repository (named in RELEASES_REPOSITORY) with the user-facing files only:
# README (without the source-only sections), CHANGELOG, LICENSE, screenshots and third-party notices.
# The source code stays in this private repository.
#
# Usage:
#   scripts/publish-public.sh             commit and push the documentation
#   scripts/publish-public.sh --release   also publish dist/release/ as GitHub release v<VERSION>,
#                                         tagged on the public repository's documentation commit
# Environment:
#   FRESH=1   replace the public history with a single commit (used once, to remove the old source)
set -euo pipefail
cd "$(dirname "$0")/.."

REPOSITORY="$(cat RELEASES_REPOSITORY)"
VERSION="$(cat VERSION)"
OUT="dist/release"

# Replacing the public history can't be undone; make the second confirmation explicit.
if [ "${FRESH:-}" = "1" ] && [ "${CONFIRM_REPLACE_HISTORY:-}" != "$REPOSITORY" ]; then
  echo "FRESH=1 replaces all history of $REPOSITORY. Re-run with CONFIRM_REPLACE_HISTORY=$REPOSITORY to proceed." >&2
  exit 1
fi
# Check the release before publishing anything, so a missing file can't leave the docs half-updated.
if [ "${1:-}" = "--release" ]; then
  for file in RELEASE_NOTES.md "Tabula-$VERSION.dmg" "Tabula-$VERSION.zip" SHA256SUMS.txt; do
    [ -f "$OUT/$file" ] || { echo "Missing $OUT/$file; run scripts/release.sh first." >&2; exit 1; }
  done
fi
# Every source-only section must be closed, or the private part would be published.
opened=$(grep -c '<!-- source-only -->' README.md || true)
closed=$(grep -c '<!-- /source-only -->' README.md || true)
if [ "$opened" != "$closed" ]; then
  echo "README.md has $opened <!-- source-only --> but $closed <!-- /source-only --> markers." >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ "${FRESH:-}" = "1" ]; then
  git -C "$work" init -q -b main
else
  git clone -q --depth 1 "https://github.com/$REPOSITORY.git" "$work"
  git -C "$work" rm -rq --ignore-unmatch . >/dev/null
fi

# The README without the parts between <!-- source-only --> and <!-- /source-only -->.
awk '/<!-- source-only -->/ {skip=1; next} /<!-- \/source-only -->/ {skip=0; next} !skip' README.md | cat -s > "$work/README.md"
cp CHANGELOG.md LICENSE "$work/"
mkdir -p "$work/docs" "$work/Resources"
cp -R docs/. "$work/docs/"
cp Resources/THIRD_PARTY_NOTICES.txt "$work/Resources/"

git -C "$work" add -A
if git -C "$work" diff --cached --quiet 2>/dev/null && [ "${FRESH:-}" != "1" ]; then
  echo "Public documentation is already up to date."
else
  git -C "$work" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -q -m "Tabula $VERSION"
  if [ "${FRESH:-}" = "1" ]; then
    git -C "$work" push -q --force "https://github.com/$REPOSITORY.git" main
  else
    git -C "$work" push -q "https://github.com/$REPOSITORY.git" main
  fi
  echo "Pushed the documentation to $REPOSITORY."
fi

if [ "${1:-}" = "--release" ]; then
  gh release create "v$VERSION" -R "$REPOSITORY" --target main --title "Tabula $VERSION" \
    --notes-file "$OUT/RELEASE_NOTES.md" --latest \
    "$OUT/Tabula-$VERSION.dmg" "$OUT/Tabula-$VERSION.zip" "$OUT/SHA256SUMS.txt"
fi
