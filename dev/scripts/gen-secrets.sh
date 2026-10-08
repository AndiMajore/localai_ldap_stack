#!/usr/bin/env bash
# Dev variant: the production secrets plus the test directory's passwords.
#   cp dev/.env.example .env && dev/scripts/gen-secrets.sh
exec "$(dirname "$0")/../../scripts/gen-secrets.sh" LDAP_BIND_PASSWORD:24 LDAP_SEED_USER_PASSWORD:16
