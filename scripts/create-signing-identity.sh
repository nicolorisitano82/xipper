#!/bin/bash
# Creates the self-signed code-signing identity used for beta builds ("Xipper Self-Signed"),
# in a dedicated keychain so the login keychain and system trust settings are untouched.
# Secrets live in ~/.xipper-signing (0700); nothing secret goes into the repository.
set -euo pipefail

NAME="Xipper Self-Signed"
DIR="$HOME/.xipper-signing"
KC="$HOME/Library/Keychains/xipper-signing.keychain-db"

if [ -f "$DIR/keychain-password" ] && [ -f "$KC" ]; then
    echo "identity already exists: $KC"
    exit 0
fi

umask 077
mkdir -p "$DIR"
KCPW=$(/usr/bin/openssl rand -hex 24)
P12PW=$(/usr/bin/openssl rand -hex 24)
printf '%s' "$KCPW" > "$DIR/keychain-password"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
O = Xipper
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# LibreSSL's PKCS#12 defaults are the ones `security import` accepts.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$P12PW"
cp "$TMP/cert.pem" "$DIR/xipper-self-signed.cer.pem"

security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 7200 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null

echo "created \"$NAME\" in $KC"
security find-identity -p codesigning "$KC"
