#!/usr/bin/env bash
# Manage users in the test OpenLDAP directory (dev only) and sync them into Authentik.
#
#   dev/scripts/ldap-user.sh add    <uid> "<Full Name>" <email> [password]   # prompts if no password
#   dev/scripts/ldap-user.sh grant  <uid> <group>        # e.g. ai-api-users, ai-admins
#   dev/scripts/ldap-user.sh revoke <uid> <group>
#   dev/scripts/ldap-user.sh passwd <uid> [password]
#   dev/scripts/ldap-user.sh delete <uid>
#   dev/scripts/ldap-user.sh list
#
# Every change is followed by an Authentik LDAP sync, so the user can log in right away.
set -euo pipefail
cd "$(dirname "$0")/../.."
COMPOSE=(docker compose -f docker-compose.yml -f dev/compose.dev.yml)

env_value() { grep -E "^$1=" .env | cut -d= -f2-; }
BASE_DN="$(env_value LDAP_BASE_DN)"
ADMIN_PW="$(env_value LDAP_BIND_PASSWORD)"
ADMIN_DN="$(env_value LDAP_BIND_DN)"

ldap() { # ldap <tool> [args...]  (stdin is passed through)
  "${COMPOSE[@]}" exec -T openldap "$1" -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" "${@:2}"
}
user_dn() { echo "uid=$1,ou=people,${BASE_DN}"; }
group_dn() { echo "cn=$1,ou=groups,${BASE_DN}"; }
ask_password() {
  local pw pw2
  read -rsp "Password for $1: " pw; echo >&2
  read -rsp "Repeat: " pw2; echo >&2
  [[ "$pw" == "$pw2" && -n "$pw" ]] || { echo "passwords empty or different" >&2; exit 1; }
  printf '%s' "$pw"
}
sync_authentik() {
  # Runs the source's user/group/membership sync inline (`ak ldap_sync` only queues a task).
  echo "Syncing Authentik with LDAP..."
  "${COMPOSE[@]}" exec -T authentik-worker ak shell -c '
from authentik.sources.ldap.models import LDAPSource
from authentik.sources.ldap.sync.users import UserLDAPSynchronizer
from authentik.sources.ldap.sync.groups import GroupLDAPSynchronizer
from authentik.sources.ldap.sync.membership import MembershipLDAPSynchronizer
from authentik.sources.ldap.sync.forward_delete_users import UserLDAPForwardDeletion
from authentik.sources.ldap.sync.forward_delete_groups import GroupLDAPForwardDeletion
source = LDAPSource.objects.get(slug="openldap")
for cls in (UserLDAPSynchronizer, GroupLDAPSynchronizer, MembershipLDAPSynchronizer,
            UserLDAPForwardDeletion, GroupLDAPForwardDeletion):
    sync = cls(source, None)
    for page in sync.get_objects():
        sync.sync(page)
print("SYNC_OK")
' 2>/dev/null | grep -q SYNC_OK || { echo "Authentik sync failed (try: docker compose -f docker-compose.yml -f dev/compose.dev.yml logs authentik-worker)" >&2; exit 1; }
  echo "Done."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    uid="${1:?uid}"; name="${2:?full name}"; mail="${3:?email}"; pw="${4:-}"
    [[ -n "$pw" ]] || pw="$(ask_password "$uid")"
    given="${name%% *}"; sn="${name##* }"
    ldap ldapadd <<EOF
dn: $(user_dn "$uid")
objectClass: inetOrgPerson
uid: $uid
cn: $name
givenName: $given
sn: $sn
mail: $mail
EOF
    ldap ldappasswd -s "$pw" "$(user_dn "$uid")"
    echo "Added $uid. Grant API access with: $0 grant $uid ai-api-users"
    sync_authentik
    ;;
  grant|revoke)
    uid="${1:?uid}"; group="${2:?group}"
    op=$([[ "$cmd" == grant ]] && echo add || echo delete)
    ldap ldapmodify <<EOF
dn: $(group_dn "$group")
changetype: modify
$op: member
member: $(user_dn "$uid")
EOF
    sync_authentik
    ;;
  passwd)
    uid="${1:?uid}"; pw="${2:-}"
    [[ -n "$pw" ]] || pw="$(ask_password "$uid")"
    ldap ldappasswd -s "$pw" "$(user_dn "$uid")"
    echo "Password changed for $uid."
    ;;
  delete)
    uid="${1:?uid}"
    # Remove group memberships first (groupOfNames keeps dangling member DNs otherwise).
    for g in $(ldap ldapsearch -LLL -b "ou=groups,${BASE_DN}" "(member=$(user_dn "$uid"))" cn | sed -n 's/^cn: //p'); do
      ldap ldapmodify <<EOF
dn: $(group_dn "$g")
changetype: modify
delete: member
member: $(user_dn "$uid")
EOF
    done
    ldap ldapdelete "$(user_dn "$uid")"
    echo "Deleted $uid."
    sync_authentik
    ;;
  list)
    echo "Users:"
    ldap ldapsearch -LLL -b "ou=people,${BASE_DN}" "(objectClass=inetOrgPerson)" uid cn mail \
      | awk '/^uid:/{u=$2} /^cn:/{sub(/^cn: /,""); c=$0} /^mail:/{m=$2} /^$/{if(u)printf "  %-12s %-24s %s\n",u,c,m; u=c=m=""} END{if(u)printf "  %-12s %-24s %s\n",u,c,m}'
    echo "Groups:"
    ldap ldapsearch -LLL -b "ou=groups,${BASE_DN}" "(objectClass=groupOfNames)" cn member \
      | awk '/^cn:/{if(g)print "  "g": "m; g=$2; m=""} /^member:/{split($2,a,/[=,]/); m=m (m?" ":"") a[2]} END{if(g)print "  "g": "m}'
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
