#!/bin/zsh
# Builds "Stickies Plus.app" into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Stickies Plus"
EXECUTABLE="StickiesPlus"
APP="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature so macOS can remember the Full Disk Access grant.
codesign --force --sign - --identifier local.stickiesplus "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  /System/Library/CoreServices/pbs -update 2>/dev/null || true  # refresh the Services menu
  echo "Installed to ~/Applications/$APP_NAME.app"
fi
