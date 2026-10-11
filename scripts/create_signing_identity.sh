#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
signing_dir="$project_root/.local/signing"
identity_name='Kukusit Local Development'
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
if [[ -f "$signing_dir/identity.sha1" ]] && security find-identity -p codesigning | rg -q "$(cat "$signing_dir/identity.sha1")"; then
  printf 'Existing local signing identity: %s\n' "$identity_name"
  exit 0
fi
private_dir="$(mktemp -d "$signing_dir/import.XXXXXX")"
chmod 700 "$private_dir"
trap 'rm -rf "$private_dir"' EXIT
cat > "$private_dir/certificate.conf" <<'CONF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Kukusit Local Development
O = Kukusit
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CONF
openssl req -new -x509 -newkey rsa:3072 -nodes -days 3650 -config "$private_dir/certificate.conf" \
  -keyout "$private_dir/key.pem" -out "$signing_dir/certificate.pem" 2> "$private_dir/openssl.log"
export KUKUSIT_IMPORT_PASS="$(openssl rand -hex 24)"
openssl pkcs12 -export -inkey "$private_dir/key.pem" -in "$signing_dir/certificate.pem" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -name "$identity_name" -out "$private_dir/identity.p12" -passout env:KUKUSIT_IMPORT_PASS
security import "$private_dir/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -f pkcs12 -P "$KUKUSIT_IMPORT_PASS" -x -T /usr/bin/codesign
openssl x509 -in "$signing_dir/certificate.pem" -noout -fingerprint -sha1 \
  | cut -d= -f2 | tr -d ':' > "$signing_dir/identity.sha1"
printf 'Created local identity in login Keychain: %s\n' "$identity_name"
