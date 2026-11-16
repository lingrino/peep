#!/bin/zsh
# Compile Sources/Core + Tests into one executable and run it.
#   Scripts/test.sh [name-filter]         # debug build (fast compile, all runtime checks on)
#   CONFIG=release Scripts/test.sh        # optimized build (catches optimizer-only issues)
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
CONFIG=${CONFIG:-debug}
OUT="$ROOT/.build/$CONFIG"
mkdir -p "$OUT"
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ "$CONFIG" == release ]]; then OPT=(-O -wmo -target-cpu apple-m4); else OPT=(-Onone -g); fi
swiftc -sdk "$SDK" -target arm64-apple-macos27.0 -swift-version 6 -module-cache-path "$ROOT/.build/module-cache" \
  "${OPT[@]}" -module-name PeepTests Sources/Core/**/*.swift Tests/*.swift -o "$OUT/peep-tests"
"$OUT/peep-tests" "$@"
