#!/bin/sh
# Sets the dev users' passwords to $LDAP_SEED_USER_PASSWORD. Safe to re-run.
set -eu
for user in alice bob carol; do
  ldappasswd -x -H ldap://openldap:389 \
    -D "cn=admin,${LDAP_BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
    -s "${LDAP_SEED_USER_PASSWORD}" "uid=${user},ou=people,${LDAP_BASE_DN}"
  echo "password set for ${user}"
done
