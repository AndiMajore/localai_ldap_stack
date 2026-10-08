# Local development

Everything in this folder is for running the stack on a workstation. It is not used in production.

`dev/compose.dev.yml` is an override on top of the production `docker-compose.yml` and adds:

- **A test LDAP directory** (`openldap`) with the users `alice`, `bob` and `carol`, plus `ldap-seed`, which sets
  their passwords on start.
- **Plain HTTP** on port 80, so no certificates are needed (`http://ai.localtest.me`, `http://auth.localtest.me`).
- **Laptop sizing**: a small decision-model set (`dev/localai/preload/laptop.yaml`), at most 2 models loaded, 10 min
  idle unload.

## Start

Run all commands from the repository root:

```bash
cp dev/.env.example .env
dev/scripts/gen-secrets.sh        # fills the empty secrets, including the test-directory passwords
docker compose -f docker-compose.yml -f dev/compose.dev.yml up -d
```

Tip (fish): `alias dc 'docker compose -f docker-compose.yml -f dev/compose.dev.yml'`, then `dc up -d`, `dc logs -f localai`, …

Passwords and API keys travel unencrypted in this mode. Use it on localhost only.

## Test users

| User | Groups | Result |
|---|---|---|
| `carol` | `ai-api-users`, `ai-admins` | Logs in; LocalAI admin (`LOCALAI_ADMIN_EMAIL`) |
| `alice` | `ai-api-users` | Logs in; normal user |
| `bob` | none | Refused by Authentik |

All share the password in `LDAP_SEED_USER_PASSWORD` (`.env`). The Authentik admin is `akadmin` /
`AUTHENTIK_BOOTSTRAP_PASSWORD`.

## Managing test users

```bash
dev/scripts/ldap-user.sh add dave "Dave Miller" dave@example.org   # prompts for the password
dev/scripts/ldap-user.sh grant dave ai-api-users                   # allow API / key UI login
dev/scripts/ldap-user.sh revoke dave ai-api-users
dev/scripts/ldap-user.sh passwd dave
dev/scripts/ldap-user.sh delete dave
dev/scripts/ldap-user.sh list
```

Each change triggers an Authentik LDAP sync right away, so you don't have to wait for the 2-hourly sync.

## Automated tests

```bash
PW=$(grep ^LDAP_SEED_USER_PASSWORD= .env | cut -d= -f2-)
# Headless SSO login (LocalAI -> Authentik -> LDAP password), prints a fresh 1-day API key:
API_KEY=$(dev/scripts/sso-login.py alice "$PW") SCHEME=http scripts/smoke.sh
dev/scripts/sso-login.py bob "$PW" --expect-denied      # not in ai-api-users
```

## Self-signed certificates

`dev/scripts/gen-certs.sh` creates a local CA and a certificate for `ai.$DOMAIN` / `auth.$DOMAIN` in `certs/`. Use it to
run the production configuration (HTTPS, without `dev/compose.dev.yml`) on a test or staging machine before real
certificates exist. Clients then need to trust `certs/ca/ca.crt`. LocalAI trusts it automatically.

## Troubleshooting

- **Login loops back to the email/username page after switching between HTTPS and HTTP**: the browser still holds
  Authentik's `Secure` session cookie from the HTTPS run, and browsers won't let an http:// page replace it. Delete
  the site data for `localtest.me` (Chrome: `chrome://settings/content/all?searchSubpage=localtest.me`), or use a
  private window.
- **Browser forces https://** after an earlier HTTPS visit (HSTS): delete `ai.localtest.me` and `auth.localtest.me`
  at `chrome://net-internals/#hsts`.
- **vllm-cpp models (e.g. Tev1) on this laptop** run on the CPU (`cpu-vllm-cpp-development` is in
  `LOCALAI_BACKENDS`), because the CUDA build of vllm-cpp needs a Blackwell GPU. Expect seconds per request.
