#!/bin/zsh
# Record a Time Profiler trace of a command and print the hottest functions.
#   Scripts/profile.sh .build/release/peep-dev lexbench file.py 400
set -euo pipefail
ROOT=${0:A:h:h}
TRACE=$(mktemp -d)/profile.trace
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctrace record --quiet --template 'Time Profiler' \
  --output "$TRACE" --launch -- "$@" >/dev/null
python3 -I "$ROOT/Scripts/profile.py" "$TRACE" "${TOP:-25}"
