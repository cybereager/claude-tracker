#!/bin/bash
# ClaudeScope Installer
# Copies the app to /Applications and removes the macOS quarantine flag
# so you don't need to right-click → Open on first launch.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/ClaudeScope.app"
DEST="/Applications/ClaudeScope.app"

echo "Installing ClaudeScope..."

# Copy to Applications
cp -r "$APP" "$DEST"

# Remove quarantine attribute (lets macOS treat it as safe)
xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true

# Register with LaunchServices so Spotlight can find it
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null || true

echo "Done! Launching ClaudeScope..."
open "$DEST"
