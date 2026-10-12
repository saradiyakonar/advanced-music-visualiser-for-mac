#!/bin/bash
# Builds the release binary and wraps it in an ad-hoc-signed .app bundle.
# Output: build/Album Visualiser.app, also copied to ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Album Visualiser.app"

swift build -c release --scratch-path .build-release
BIN="$(swift build -c release --scratch-path .build-release --show-bin-path)/AlbumVisualiser"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AlbumVisualiser"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none --identifier com.saradiya.albumvisualiser "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Album Visualiser.app"
cp -R "$APP" "$HOME/Applications/"
echo "Built $APP"
