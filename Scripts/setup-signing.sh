#!/bin/zsh
# One-time, per-machine: create a self-signed code-signing identity in a dedicated keychain.
#
# Why: macOS privacy permissions (Accessibility, which the key-forwarding agent needs) are
# bound to the app's *designated requirement*. Ad-hoc signatures change on every build, which
# silently revokes the permission. A stable certificate makes the requirement
#   identifier "com.lingrino.peep" and certificate leaf = H"<cert hash>"
# which survives rebuilds. The certificate is untrusted and never leaves this machine;
# codesign accepts it without any trust settings.
#
# The keychain password is random and stored as a generic password in the login keychain
# (service "peep-signing-keychain"); Scripts/build.sh reads it to unlock before signing.
# If this script has not been run, build.sh falls back to ad-hoc signing.
set -euo pipefail

NAME="Peep Local Signing"
KC="$HOME/Library/Keychains/peep-signing.keychain-db"
SERVICE="peep-signing-keychain"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already exists in $KC"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Peep Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
# /usr/bin/openssl (LibreSSL) writes PKCS#12 that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 7300 -config "$TMP/cert.cnf" 2>/dev/null
P12PW=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout "pass:$P12PW" -name "$NAME"

KCPW=$(/usr/bin/openssl rand -hex 24)
security delete-generic-password -s "$SERVICE" >/dev/null 2>&1 || true
security add-generic-password -s "$SERVICE" -a peep -w "$KCPW"
[[ -f "$KC" ]] && security delete-keychain "$KC"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$KCPW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
security find-identity -p codesigning "$KC"
echo "created '$NAME' in $KC"
