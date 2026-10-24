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
  OUT="dist/release"
  gh release create "v$VERSION" -R "$REPOSITORY" --target main --title "Tabula $VERSION" \
    --notes-file "$OUT/RELEASE_NOTES.md" --latest \
    "$OUT/Tabula-$VERSION.dmg" "$OUT/Tabula-$VERSION.zip" "$OUT/SHA256SUMS.txt"
fi
