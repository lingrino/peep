#!/bin/zsh
# Record a Time Profiler trace of a command and print the hottest functions.
#   Scripts/profile.sh .build/release/peep-dev lexbench file.py 400
set -euo pipefail
ROOT=${0:A:h:h}
mkdir -p "$ROOT/.build/profile"
TRACE="$ROOT/.build/profile/$(date +%Y%m%d-%H%M%S).trace"   # kept for FOCUS=... profile.py runs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctrace record --quiet --template 'Time Profiler' \
  --output "$TRACE" --launch -- "$@" >/dev/null
python3 -I "$ROOT/Scripts/profile.py" "$TRACE" "${TOP:-25}"
echo "trace: $TRACE"
