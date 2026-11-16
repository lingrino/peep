#!/bin/zsh
# Build Peep.app (host app + Quick Look preview extension) by calling swiftc directly.
#
# There is no SwiftPM/Xcode project on purpose: the shared core (Sources/Core) is compiled
# *into* each binary as one whole module, so the optimizer sees everything (no cross-module
# boundaries, full specialization/inlining), and every flag is visible right here.
#
#   Scripts/build.sh                 # release build -> .build/Peep.app
#   Scripts/build.sh install         # ...and install to /Applications + register extension
#   CONFIG=debug Scripts/build.sh    # unoptimized build with debug info
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
CONFIG=${CONFIG:-release}
OUT="$ROOT/.build/$CONFIG"
mkdir -p "$OUT"

# Toolchain: the Command Line Tools by default (override with DEVELOPER_DIR=...).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-macos27.0
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 6 -module-cache-path "$ROOT/.build/module-cache")
if [[ "$CONFIG" == release ]]; then
  # -O + WMO; exclusivity checks off (runtime call on each class/global access);
  # tuned for Apple M4-class cores (the only hardware this ever runs on).
  OPT=(-O -wmo -enforce-exclusivity=unchecked -target-cpu apple-m4)
else
  OPT=(-Onone -g -DDEBUG)
fi

CORE=(Sources/Core/**/*.swift(N) Sources/Render/**/*.swift(N))

# Quick Look extension: Sources/Preview/main.swift starts the background warm-up, then calls
# NSExtensionMain (from Foundation).
swiftc "${COMMON[@]}" "${OPT[@]}" -application-extension \
  -module-name PeepPreview "${CORE[@]}" Sources/Preview/**/*.swift(N) \
  -Xlinker -application_extension \
  -o "$OUT/PeepPreview" &
P1=$!
swiftc "${COMMON[@]}" "${OPT[@]}" -module-name Peep "${CORE[@]}" Sources/App/**/*.swift(N) \
  -o "$OUT/Peep" &
P2=$!
wait $P1; wait $P2

APP="$ROOT/.build/Peep.app"
APPEX="$APP/Contents/PlugIns/PeepPreview.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$OUT/Peep" "$APP/Contents/MacOS/Peep"
cp "$OUT/PeepPreview" "$APPEX/Contents/MacOS/PeepPreview"
cp Bundle/Peep-Info.plist "$APP/Contents/Info.plist"
cp Bundle/PeepPreview-Info.plist "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[[ -f Bundle/AppIcon.icns ]] && cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Release: strip local symbols (smaller binary = fewer pages to fault in at launch).
if [[ "$CONFIG" == release ]]; then
  strip -x "$APP/Contents/MacOS/Peep" "$APPEX/Contents/MacOS/PeepPreview"
fi

# Sign with the stable local identity (Scripts/setup-signing.sh) so privacy permissions
# survive rebuilds; fall back to ad-hoc. Inner bundle first.
KC="$HOME/Library/Keychains/peep-signing.keychain-db"
SIGN=(--sign -)
if [[ -f "$KC" ]] && KCPW=$(security find-generic-password -s peep-signing-keychain -w 2>/dev/null); then
  security unlock-keychain -p "$KCPW" "$KC"
  SIGN=(--keychain "$KC" --sign "Peep Local Signing")
else
  echo "warning: no local signing identity; ad-hoc signing (run Scripts/setup-signing.sh)" >&2
fi
codesign --force "${SIGN[@]}" --options runtime --entitlements Bundle/PeepPreview.entitlements "$APPEX"
codesign --force "${SIGN[@]}" --options runtime --entitlements Bundle/Peep.entitlements "$APP"
echo "built $APP"

if [[ "${1:-}" == install ]]; then
  DEST=/Applications/Peep.app
  # Update in place (never delete the bundle): Background Task Management drops its record
  # of the keyboard agent when the app bundle disappears.
  mkdir -p "$DEST"
  rsync -a --delete "$APP/" "$DEST/"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/PeepPreview.appex"
  pluginkit -e use -i com.lingrino.peep.preview
  # Kill any running extension instance + reset Quick Look so the new build is used.
  killall PeepPreview 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  # (Re)load the keyboard agent LaunchAgent on the new binary.
  "$DEST/Contents/MacOS/Peep" --register
  echo "installed $DEST"
fi
