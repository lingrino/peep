#!/bin/zsh
# Build the developer tool (Dev/) and run it: Scripts/dev.sh render file.swift /tmp/x.png
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
CONFIG=${CONFIG:-release}
OUT="$ROOT/.build/$CONFIG"
mkdir -p "$OUT"
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ "$CONFIG" == release ]]; then OPT=(-O -wmo -enforce-exclusivity=unchecked -target-cpu apple-m4); else OPT=(-Onone -g); fi
SRC=(Sources/Core/**/*.swift Sources/Render/**/*.swift Dev/*.swift)
STAMP="$OUT/peep-dev.stamp"
if [[ ! -x "$OUT/peep-dev" ]] || [[ -n "$(find "${SRC[@]}" -newer "$OUT/peep-dev" 2>/dev/null | head -1)" ]]; then
  swiftc -sdk "$SDK" -target arm64-apple-macos27.0 -swift-version 6 -module-cache-path "$ROOT/.build/module-cache" \
    "${OPT[@]}" -module-name PeepDev "${SRC[@]}" -o "$OUT/peep-dev"
fi
exec "$OUT/peep-dev" "$@"
