#!/bin/bash
# Create a STABLE self-signed code-signing identity in the login keychain.
# Why: ad-hoc (`codesign -s -`) gives a new cdhash every build, so macOS treats each
# rebuild as a new app and Accessibility permission must be re-granted. Signing with a
# fixed cert makes the app's designated requirement reference the cert (stable) instead
# of the cdhash, so you grant Accessibility ONCE and it survives every rebuild.
#
# Idempotent: if the identity already exists, it does nothing.
set -euo pipefail

CERT_NAME="HiDisplay Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> identity '$CERT_NAME' already exists — nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = HiDisplay Local Signing
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> generating self-signed code-signing certificate (10y)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

# -legacy + sha1 MAC: macOS Security framework can't read OpenSSL 3.x's modern PKCS12 MAC.
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass:qmf >/dev/null 2>&1

echo "==> importing into login keychain (codesign-accessible, no prompt)"
# -A: any app may use the key without warning (lets codesign sign non-interactively).
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P qmf -A -T /usr/bin/codesign >/dev/null 2>&1

echo "==> done. Identity installed:"
security find-certificate -c "$CERT_NAME" "$KEYCHAIN" | grep -E '"labl"' || true
