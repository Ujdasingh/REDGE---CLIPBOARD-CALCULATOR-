#!/bin/bash
# Create a stable self-signed code-signing identity so macOS TCC
# (Accessibility / Input Monitoring / Automation) survives app updates.
# Ad-hoc signing (codesign -s -) changes the app identity on every build,
# which is why Accessibility asked again after each update.
set -e
CN="Redge Developer"
P12_PASS="redge-local-sign"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CN\""; then
    echo "Signing identity '$CN' already exists."
    exit 0
fi

echo "Creating stable signing identity '$CN' (one-time)..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Redge Developer
O = Redge
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -new -x509 -days 3650 -nodes \
    -newkey rsa:2048 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -config "$TMP/cert.cnf"

openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/redge.p12" \
    -passout pass:"$P12_PASS" \
    -name "$CN" \
    -legacy 2>/dev/null || openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/redge.p12" \
    -passout pass:"$P12_PASS" \
    -name "$CN" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ ! -f "$KEYCHAIN" ]; then
    KEYCHAIN="$HOME/Library/Keychains/login.keychain"
fi

security import "$TMP/redge.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Self-signed certs are not codesign-valid until trusted in the keychain.
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || true

# Allow codesign to use the key without a GUI password prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CN\""; then
    echo "WARNING: '$CN' is in the keychain but not yet a valid codesigning identity."
    echo "Open Keychain Access, find 'Redge Developer', and set Trust → Code Signing to 'Always Trust'."
    exit 1
fi

echo "Created signing identity '$CN'."
