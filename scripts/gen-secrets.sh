#!/usr/bin/env bash
# Fills every empty secret in .env with a random value; existing values are left alone.
#   cp .env.example .env && scripts/gen-secrets.sh
# Extra variable names can be passed as arguments (used by dev/scripts/gen-secrets.sh).
# LDAP_BIND_PASSWORD is not generated: it belongs to your directory's service account.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found (cp .env.example .env first)" >&2; exit 1; }

# key:length  (Postgres passwords must stay below 100 characters)
SECRETS=(PG_PASS:40 LOCALAI_DB_PASS:40 AUTHENTIK_SECRET_KEY:64 AUTHENTIK_BOOTSTRAP_PASSWORD:24
         LOCALAI_OIDC_CLIENT_SECRET:64 "$@")

rand() { openssl rand -base64 96 | tr -d '\n=+/' | cut -c1-"$1"; }

for entry in "${SECRETS[@]}"; do
  key="${entry%%:*}"; len="${entry##*:}"; [[ "$len" == "$key" ]] && len=24
  if grep -qE "^${key}=$" .env; then
    sed -i "s|^${key}=$|${key}=$(rand "$len")|" .env
    echo "generated ${key}"
  elif grep -qE "^${key}=" .env; then
    echo "kept      ${key} (already set)"
  else
    echo "${key}=$(rand "$len")" >> .env
    echo "added     ${key}"
  fi
done
chmod 600 .env
