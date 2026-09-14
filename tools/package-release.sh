#!/bin/bash
# Package a HiDisplay release: build the .app, zip it, and compute its sha256. Publishing to
# GitHub is opt-in (--publish) so this never makes an outward-facing change by accident. Usage:
#   tools/package-release.sh            # build + zip + sha256 (local only)
#   tools/package-release.sh --publish  # also create the GitHub release and upload the zip
#   tools/package-release.sh --publish-existing  # CI: upload to the release for the pushed tag
set -euo pipefail

cd "$(dirname "$0")/.."

PUBLISH=0
case "${1:-}" in
    --publish) PUBLISH=1 ;;
    --publish-existing) PUBLISH=2 ;;
esac

APP_NAME="HiDisplay"
# Single source of truth for the version: AppModel.swift, same as build-app.sh reads. (This used to
# scrape build-app.sh's VERSION= line, which silently broke when that line became a command.)
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/HiDisplay/AppModel.swift)"
[ -n "$VERSION" ] || { echo "error: could not read AppModel.version" >&2; exit 1; }
case "$VERSION" in
    [0-9]*.[0-9]*) ;;
    *) echo "error: version '$VERSION' does not look like a version number" >&2; exit 1 ;;
esac
TAG="v${VERSION}"

APP="build/${APP_NAME}.app"
ZIP="dist/${APP_NAME}.zip"

echo "==> building ${APP_NAME} ${VERSION}"
./build-app.sh

echo "==> zipping ${APP} -> ${ZIP}"
mkdir -p dist
rm -f "$ZIP"
# ditto --keepParent preserves the .app bundle structure and code signature (plain `zip` can mangle it).
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256: ${SHA}"
# Shipped next to the zip so a download can be checked without trusting the release page text.
SHAFILE="${ZIP}.sha256"
echo "${SHA}  $(basename "$ZIP")" > "$SHAFILE"

if [ "$PUBLISH" -ge 1 ]; then
    command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
    if [ "$PUBLISH" -eq 1 ]; then
        # A release is a public statement about a commit: refuse a dirty tree or an unpushed HEAD.
        # Untracked files (local plans, editor state) are not part of the release; tracked changes are.
        [ -z "$(git status --porcelain --untracked-files=no)" ] \
            || { echo "error: working tree has uncommitted tracked changes" >&2; exit 1; }
        git fetch -q origin
        git merge-base --is-ancestor HEAD origin/main \
            || { echo "error: HEAD is not pushed to origin/main" >&2; exit 1; }
    fi
    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "==> release ${TAG} exists; uploading assets (clobber)"
        gh release upload "$TAG" "$ZIP" "$SHAFILE" --clobber
    else
        echo "==> creating GitHub release ${TAG}"
        # --generate-notes auto-builds release notes from merged commits. No error is swallowed:
        # an auth or network failure here used to surface as a misleading upload failure.
        gh release create "$TAG" "$ZIP" "$SHAFILE" --title "$TAG" --generate-notes
    fi
    echo "==> published: $(gh release view "$TAG" --json url -q .url)"
else
    echo ""
    echo "==> done (local). Publish with: tools/package-release.sh --publish"
fi
