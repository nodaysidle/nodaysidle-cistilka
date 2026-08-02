#!/usr/bin/env bash
# Build Cistilka.app (if needed) and wrap it in a release DMG.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ -f "$ROOT/version.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/version.env"
fi

APP_NAME=${APP_NAME:-Cistilka}
VERSION=${VERSION:-${MARKETING_VERSION:-0.1.0}}
BUILD_NUMBER=${BUILD_NUMBER:-1}
DMG_NAME="${APP_NAME}-${VERSION}"
STAGING="$ROOT/.dmg-staging"
OUT_DMG="$ROOT/dist/${DMG_NAME}.dmg"

mkdir -p "$ROOT/dist"

# Ensure a fresh signed .app exists.
SIGNING_MODE=${SIGNING_MODE:-adhoc}
export SIGNING_MODE
./Scripts/package_app.sh release

APP_SRC="$ROOT/${APP_NAME}.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "ERROR: ${APP_SRC} not found after package_app.sh" >&2
  exit 1
fi

# Bundle OAuth.example only (never real OAuth.plist secrets).
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_SRC" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

# Optional background / README in DMG root
cat > "$STAGING/README.txt" <<EOF
${APP_NAME} ${VERSION} (${BUILD_NUMBER})

1. Drag ${APP_NAME} to Applications
2. Open ${APP_NAME} (right-click → Open on first launch if prompted)
3. System Settings → Privacy & Security → Full Disk Access → enable ${APP_NAME}

https://github.com/nodaysidle/nodaysidle-cistilka
EOF

rm -f "$OUT_DMG"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT_DMG"

rm -rf "$STAGING"

echo "Created $OUT_DMG"
ls -lh "$OUT_DMG"
