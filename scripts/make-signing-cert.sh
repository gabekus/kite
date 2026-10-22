#!/usr/bin/env bash
# Creates a self-signed code-signing identity, "Kite Local Signing", in the login
# keychain. bundle-app.sh signs with it, so every rebuild keeps the same code
# identity and the keychain's "Always Allow" for Kite sticks.
# Run once per Mac. Remove with: security delete-identity -c "Kite Local Signing"
set -euo pipefail

NAME="Kite Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# macOS's LibreSSL writes a PKCS#12 that `security import` reads; OpenSSL 3
# would need -legacy, so call the system binary explicitly.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:kite -out "$TMP/identity.p12"
# -T lets codesign use the key without its own keychain prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P kite -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". bundle-app.sh will sign with it from now on."
