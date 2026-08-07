#!/bin/bash
# Removes the Translit LaunchAgent, app bundle and CLI symlink.
set -euo pipefail

LABEL="com.arsidian.translit"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/${LABEL}.plist"
rm -rf "$HOME/Applications/Translit.app"
rm -f "$HOME/.local/bin/translit"
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true

echo "Translit removed."
