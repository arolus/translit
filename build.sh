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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s|__VERSION__|$VERSION|g" assets/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/translit"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature — stable identity for the TCC (Accessibility) database.
codesign --force --sign - "$APP" 2>/dev/null || echo "⚠️ codesign failed (not critical)"

echo "==> Done: $(pwd)/$APP (version $VERSION)"
