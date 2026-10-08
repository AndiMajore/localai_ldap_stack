#!/usr/bin/env bash
# Creates a local CA and a self-signed certificate for ai.$DOMAIN and auth.$DOMAIN, to try the
# production (HTTPS) configuration locally without real certificates:
#   dev/scripts/gen-certs.sh && docker compose up -d     # base compose only, served over https
# Production uses real certificates in certs/stack.crt + certs/stack.key instead.
#   certs/ca/ca.crt        CA certificate: trust it in your browser / clients
#   certs/ca-private/ca.key CA key: keep private, never mounted into containers
set -euo pipefail
cd "$(dirname "$0")/../.."
DOMAIN="${DOMAIN:-$(grep -E '^DOMAIN=' .env 2>/dev/null | cut -d= -f2)}"
DOMAIN="${DOMAIN:?set DOMAIN in .env or the environment}"
mkdir -p certs/ca certs/ca-private
chmod 700 certs/ca-private

if [[ ! -f certs/ca-private/ca.key ]]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout certs/ca-private/ca.key -out certs/ca/ca.crt \
    -subj "/CN=Embedder Stack Local CA"
fi

openssl req -newkey rsa:2048 -nodes -keyout certs/stack.key -out certs/stack.csr \
  -subj "/CN=ai.${DOMAIN}"
openssl x509 -req -in certs/stack.csr -CA certs/ca/ca.crt -CAkey certs/ca-private/ca.key \
  -CAcreateserial -out certs/stack.crt -days 825 -sha256 \
  -extfile <(printf "subjectAltName=DNS:ai.%s,DNS:auth.%s\nextendedKeyUsage=serverAuth\n" "$DOMAIN" "$DOMAIN")
rm -f certs/stack.csr certs/ca/ca.srl certs/ca-private/ca.srl
chmod 644 certs/stack.crt certs/ca/ca.crt
chmod 640 certs/stack.key
echo "Wrote certs/stack.crt for ai.${DOMAIN}, auth.${DOMAIN}; CA at certs/ca/ca.crt"
