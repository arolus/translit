#!/bin/bash
# Builds Translit.app and installs it as a LaunchAgent (starts at login).
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.arsidian.translit"
APP_SRC="$(pwd)/Translit.app"
APP_DST="$HOME/Applications/Translit.app"
BIN_DST="$APP_DST/Contents/MacOS/translit"
BIN_LINK="$HOME/.local/bin/translit"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

if [ ! -d "$APP_SRC" ] || [ ! -x "$APP_SRC/Contents/MacOS/translit" ]; then
    echo "==> Bundle not found, building..."
    ./build.sh
fi

echo "==> Installing $APP_DST"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DST" || true

# The ad-hoc signature changes with every build → the old TCC entry points at
# the previous binary and looks enabled while not working. Reset it so the
# fresh copy can raise the system prompt again.
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true

# Dictionary files: symlink ~/.config/translit into the dotfiles checkout so
# rules/exceptions sync between machines. An existing real directory is
# merged in only if the repo copy is missing those files, then replaced.
REPO_ROOT="$(cd ../.. && pwd)"
DICT_REPO="$REPO_ROOT/.config/translit"
DICT_HOME="$HOME/.config/translit"
if [ -d "$DICT_REPO" ] && [ ! -L "$DICT_HOME" ]; then
    mkdir -p "$HOME/.config"
    if [ -d "$DICT_HOME" ]; then
        for f in rules.txt exceptions.txt; do
            [ -f "$DICT_HOME/$f" ] && [ ! -f "$DICT_REPO/$f" ] && cp "$DICT_HOME/$f" "$DICT_REPO/"
        done
        rm -rf "$DICT_HOME"
    fi
    ln -s "$DICT_REPO" "$DICT_HOME"
    echo "==> Dictionary symlinked: $DICT_HOME -> $DICT_REPO"
fi

echo "==> CLI symlink: $BIN_LINK"
mkdir -p "$(dirname "$BIN_LINK")"
ln -sf "$BIN_DST" "$BIN_LINK"

echo "==> Installing LaunchAgent at $PLIST_DST"
mkdir -p "$(dirname "$PLIST_DST")"
mkdir -p "$HOME/Library/Logs"
sed -e "s|__TRANSLIT_BIN__|$BIN_DST|g" \
    -e "s|__TRANSLIT_LOGS__|$HOME/Library/Logs|g" \
    com.arsidian.translit.plist > "$PLIST_DST"

echo "==> Loading the agent..."
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"

echo ""
echo "Done. Translit is running and will start at login."
echo "  Permission: System Settings → Privacy & Security → Accessibility → allow Translit"
echo "              (the system prompt appears on first start)"
echo "  Logs:       tail -f \$HOME/Library/Logs/translit.err.log"
echo "  Version:    translit --version"
echo "  Remove:     ./uninstall.sh"
