#!/bin/zsh
# Regenerates QLSupportedContentTypes in Bundle/PeepPreview-Info.plist from the language
# table (Sources/Core/Lex/Language.swift). Run after adding languages or extensions.
#
# Quick Look matches *exact* UTIs (no conformance), so every concrete type is listed: the
# system's UTI for each extension, the dynamic UTI used when no app declares it, and common
# third-party aliases.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
Scripts/dev.sh types > .build/types.txt
python3 -I - "$ROOT/Bundle/PeepPreview-Info.plist" "$ROOT/.build/types.txt" <<'PY'
import sys, re
plist, types = sys.argv[1], open(sys.argv[2]).read().rstrip("\n")
s = open(plist).read()
s = re.sub(r"(<key>QLSupportedContentTypes</key>\s*<array>\n).*?(\n\t\t\t</array>)",
           lambda m: m.group(1) + types + m.group(2), s, flags=re.S)
open(plist, "w").write(s)
PY
echo "$(wc -l < .build/types.txt | tr -d ' ') content types"
