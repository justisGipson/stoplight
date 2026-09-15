#!/bin/bash
# Runs the suite.
#
# With full Xcode installed, XCTest is present and SwiftPM wires up Swift Testing's
# search paths by itself — plain `swift test` works. With only Command Line Tools
# (no XCTest), it does not, even though Testing.framework ships inside CLT. In that
# case we point at the framework and its interop dylib by hand.
set -euo pipefail
cd "$(dirname "$0")"

DEVELOPER_DIR="$(xcode-select -p)"

# Only full Xcode has a Platforms directory; CLT does not.
if [ -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
    exec swift test "$@"
fi

FW="$DEVELOPER_DIR/Library/Developer/Frameworks"
LIB="$DEVELOPER_DIR/Library/Developer/usr/lib"

if [ ! -d "$FW/Testing.framework" ]; then
    echo "Testing.framework not found under $FW" >&2
    echo "Install Xcode, or a Command Line Tools version that bundles Swift Testing." >&2
    exit 1
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
