#!/bin/bash
# Assembles Stoplight.app. No Xcode required — SwiftPM builds the binary and we
# lay out the bundle by hand.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Stoplight.app"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Stoplight" "$APP/Contents/MacOS/Stoplight"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: unsigned bundles get killed on launch on Apple Silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed"

echo "built $APP"
