#!/usr/bin/env bash
# Creates a self-signed code-signing identity in the login keychain for local and unnotarized builds.
#
# Why: an ad-hoc signature changes with every build, and the Keychain only trusts the exact app that
# stored a password, so each new build asks for the login password again. A signature from a fixed
# certificate keeps the same identity across builds and updates, so "Always Allow" sticks.
#
# Environment:
#   IDENTITY_NAME  certificate name (default: "Tabula Local Signing")
#   KEYCHAIN       target keychain (default: login keychain)
set -euo pipefail

IDENTITY_NAME="${IDENTITY_NAME:-Tabula Local Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
VALID_DAYS="${VALID_DAYS:-3650}"

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "“$IDENTITY_NAME” already exists in $KEYCHAIN."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days "$VALID_DAYS" -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY_NAME" \
  -out "$work/identity.p12" -passout "pass:$pass" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY_NAME" \
       -out "$work/identity.p12" -passout "pass:$pass"
# -T lets codesign use the key without a prompt on every build.
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign
echo "Created “$IDENTITY_NAME”. scripts/build-app.sh signs with it automatically."
