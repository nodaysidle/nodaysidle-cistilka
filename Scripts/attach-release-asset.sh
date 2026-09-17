#!/usr/bin/env bash
# Attach one or more locally built DMG/zip assets to an existing GitHub Release for this tag.
# Usage: Scripts/attach-release-asset.sh v0.2.0 ./path/to/Cistilka-0.2.0.dmg [./path/to/Cistilka-0.2.0.zip ...]
set -euo pipefail

TAG="${1:-}"
shift || true
REPO="${REPO:-nodaysidle/nodaysidle-cistilka}"

if [[ -z "$TAG" || $# -lt 1 ]]; then
  echo "Usage: $0 <tag> <asset-path> [asset-path ...]" >&2
  exit 1
fi

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG not found on $REPO. Push the tag first so CI can create the release, or:" >&2
  echo "  gh release create \"$TAG\" --repo \"$REPO\" --generate-notes --title \"Cistilka $TAG\"" >&2
  exit 1
fi

for ASSET in "$@"; do
  if [[ ! -f "$ASSET" ]]; then
    echo "Asset not found: $ASSET" >&2
    exit 1
  fi
  gh release upload "$TAG" "$ASSET" --repo "$REPO" --clobber
  echo "Attached $(basename "$ASSET") → $TAG on $REPO"
done
