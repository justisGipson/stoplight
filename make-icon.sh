#!/bin/bash
# Regenerates Resources/Stoplight.icns from Resources/icon-source.png.
#
# The .icns is committed, so a normal build does not need this — run it only when
# the source art changes.
set -euo pipefail
cd "$(dirname "$0")"

SRC="Resources/icon-source.png"
SET="$(mktemp -d)/Stoplight.iconset"
mkdir -p "$SET"

# The source is 512x512, so 512@2x (1024) is deliberately omitted rather than
# shipped as an upscale: macOS scales the 512 down itself and the result is no
# worse, without pretending to detail the art does not have.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    retina=$(( size * 2 ))
    if [ "$retina" -le 512 ]; then
        sips -z "$retina" "$retina" "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done

iconutil -c icns "$SET" -o Resources/Stoplight.icns
rm -rf "$(dirname "$SET")"
echo "wrote Resources/Stoplight.icns ($(du -h Resources/Stoplight.icns | cut -f1))"
