#!/bin/bash
# Build an .icns from a 1024x1024 master PNG: dist/make-icns.sh assets/AppIcon-1024.png Resources/AppIcon.icns
set -euo pipefail
SRC="${1:?usage: make-icns.sh <1024px.png> <out.icns>}"
OUT="${2:?usage: make-icns.sh <1024px.png> <out.icns>}"
WORK="$(mktemp -d)"
SET="${WORK}/AppIcon.iconset"
mkdir -p "${SET}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${SRC}" --out "${SET}/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "${SRC}" --out "${SET}/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$(dirname "${OUT}")"
iconutil -c icns "${SET}" -o "${OUT}"
rm -rf "${WORK}"
echo "Wrote ${OUT}"
