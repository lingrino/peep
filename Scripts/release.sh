#!/bin/bash
# Build a Peep release and the Homebrew cask that installs it (what CI publishes).
#   Scripts/release.sh  ->  .build/dist/Peep.app, Peep-<version>.zip, peep.rb, version
#
# Version and signing: see build.sh (PEEP_SIGN_IDENTITY; "-" for an unsigned dry run).
# Notarization runs when an App Store Connect API key is given: PEEP_NOTARY_KEY (path to
# the .p8), PEEP_NOTARY_KEY_ID, PEEP_NOTARY_ISSUER. The ticket is stapled to the app
# before zipping, so Gatekeeper accepts it offline.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/dist
rm -rf "$OUT"
mkdir -p "$OUT"

CONFIG=release Scripts/build.sh
ditto .build/Peep.app "$OUT/Peep.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/Peep.app/Contents/Info.plist")"
ZIP="$OUT/Peep-$VERSION.zip"
codesign --verify --strict --deep "$OUT/Peep.app"

if [[ -n "${PEEP_NOTARY_KEY:-}" ]]; then
  ditto -c -k --keepParent "$OUT/Peep.app" "$OUT/notarize.zip"
  result="$(xcrun notarytool submit "$OUT/notarize.zip" --wait --output-format json \
    --key "$PEEP_NOTARY_KEY" --key-id "$PEEP_NOTARY_KEY_ID" --issuer "$PEEP_NOTARY_ISSUER")"
  echo "$result"
  rm "$OUT/notarize.zip"
  if [[ "$(jq -r .status <<<"$result")" != Accepted ]]; then
    xcrun notarytool log "$(jq -r .id <<<"$result")" \
      --key "$PEEP_NOTARY_KEY" --key-id "$PEEP_NOTARY_KEY_ID" --issuer "$PEEP_NOTARY_ISSUER" || true
    echo "release: notarization failed" >&2
    exit 1
  fi
  xcrun stapler staple "$OUT/Peep.app"
  spctl --assess --type execute --verbose "$OUT/Peep.app"
fi

ditto -c -k --keepParent "$OUT/Peep.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Upgrades: brew swaps /Applications/Peep.app; the keyboard agent sees its executable
# replaced and exits, launchd starts the new one (KeepAlive), and it ends the extension
# processes still running the old code (Agent.swift, `restartWhenReplaced`). No `uninstall
# launchctl:`: brew runs uninstall stanzas on every upgrade too, and only opening Peep.app
# registers the agent again; `zap` removes it. A fresh install needs Peep.app opened once
# (it registers the agent, which asks for Accessibility).
# postflight clears the quarantine flag brew puts on every copy it installs, as fred's cask
# does: otherwise macOS asks "downloaded from the Internet… open it?" before the agent or
# the extension run new code. brew's sha256 check still pins the bits to the zip CI
# notarized. The macOS minimum is LSMinimumSystemVersion's job.
cat > "$OUT/peep.rb" <<EOF
cask "peep" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/lingrino/peep/releases/download/v#{version}/Peep-#{version}.zip"
  name "Peep"
  desc "Quick Look previews for source code and Markdown"
  homepage "https://github.com/lingrino/peep"

  depends_on arch: :arm64

  app "Peep.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-d", "-r", "com.apple.quarantine", "{{appdir}}/Peep.app"]
  end

  zap launchctl: "com.lingrino.peep.agent"
end
EOF
echo "$VERSION" > "$OUT/version"
echo "release: $ZIP ($SHA)"
