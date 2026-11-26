#!/bin/zsh
# Creates a self-signed code-signing certificate "AudioHub Local Signing" in your login keychain.
# It is used only to sign your own AudioHub builds so macOS remembers the audio-capture and
# local-network permissions across rebuilds. It is not trusted for anything else.
set -e
NAME="AudioHub Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes PKCS#12 that the macOS keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cs.cnf" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 12)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:$PASS -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P $PASS -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build.sh."
