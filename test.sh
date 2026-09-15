#!/bin/bash
# Runs the suite. The flags exist because this machine has Command Line Tools but
# not full Xcode: Testing.framework ships in CLT, but SwiftPM only wires up its
# search paths when XCTest is present, which it isn't. So we point at both the
# framework and its interop dylib by hand.
set -euo pipefail
cd "$(dirname "$0")"

CLT="$(xcode-select -p)"
FW="$CLT/Library/Developer/Frameworks"
LIB="$CLT/Library/Developer/usr/lib"

if [ ! -d "$FW/Testing.framework" ]; then
    echo "Testing.framework not found under $FW" >&2
    exit 1
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
