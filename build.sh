#!/bin/bash
# Rebuilds the translit binary and the Translit.app bundle.
# The bundle gives a stable identity for the Accessibility (TCC) permission.
set -euo pipefail
cd "$(dirname "$0")"

# Version lives in VERSION (MAJOR.MINOR.PATCH). A new VERSION pushed to the
# public mirror triggers a CI release, so bumping is a deliberate act:
# plain ./build.sh builds the version as-is; ./build.sh --bump increments
# PATCH first. (--no-bump is accepted for compatibility and is a no-op.)
if [ "${1:-}" = "--bump" ]; then
    PREV="$(tr -d '[:space:]' < VERSION)"
    MAJOR="${PREV%%.*}"
    MINOR="$(echo "$PREV" | cut -d. -f2)"
    PATCH="$(echo "$PREV" | cut -d. -f3)"
    VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    printf '%s\n' "$VERSION" > VERSION
else
    VERSION="$(tr -d '[:space:]' < VERSION)"
fi

echo "==> Compiling translit $VERSION (swift build)..."
swift build -c release
BIN=".build/release/translit"

echo "==> Building Translit.app..."
APP="Translit.app"
# Assemble in a staging dir and swap at the end: the existing bundle may be
# the one currently running, and deleting a busy bundle fails half-way.
STAGE="$APP.tmp"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
sed "s|__VERSION__|$VERSION|g" assets/Info.plist > "$STAGE/Contents/Info.plist"
cp "$BIN" "$STAGE/Contents/MacOS/translit"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

# Ad-hoc signature — stable identity for the TCC (Accessibility) database.
codesign --force --sign - "$STAGE" 2>/dev/null || echo "⚠️ codesign failed (not critical)"

if ! rm -rf "$APP" 2>/dev/null; then
    echo "==> $APP is busy (Translit running from this folder?) — stopping it..."
    killall translit 2>/dev/null || true
    sleep 1
    rm -rf "$APP"
fi
mv "$STAGE" "$APP"

echo "==> Done: $(pwd)/$APP (version $VERSION)"
