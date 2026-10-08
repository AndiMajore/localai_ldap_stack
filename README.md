# Embedder stack

Self-hosted API for **embeddings**, **reranking** and **decision models** (Jev/SystemOne style:
`state` + typed `choice` / `score` / `noul` questions → calibrated answers). The setup is like Ollama + Open WebUI,
but it serves no chat or completion endpoints. Users sign in with SSO (your LDAP/AD via Authentik) and create their
own API keys.

This is the **production** setup. It runs behind an Apache vhost on the host, which handles HTTPS. For local
development (test directory, no Apache, laptop sizing) see [`dev/README.md`](dev/README.md).

```
client ──https──► Apache :443 ──http──► Traefik 127.0.0.1:8081 ─┬─ ai.<domain>:  chat/completions/images/... → 403
   (your certificates)                                          │                /v1/embeddings /v1/rerank /v1/systemone
                                                                │                LocalAI UI: SSO login, API keys, admin
                                                                └─ auth.<domain>: Authentik ◄── LDAP sync ── your LDAP / AD
```

| Service | Role |
|---|---|
| `traefik` | Routing, blocks generative endpoints, per-key rate limit. Only service with a published port (`127.0.0.1:8081`). |
| `authentik-server` / `-worker` | Identity provider. Syncs users and groups from your directory and issues OIDC logins for LocalAI. |
| `postgres` | Databases `authentik` (IdP config, synced users, sessions) and `localai` (LocalAI users, hashed API keys, usage). |
| `localai` | Runs the models: `/v1/embeddings`, `/v1/rerank`, `/v1/systemone`. Built-in multi-user auth, per-user API keys, idle unload. |
| one-shot helpers | `authentik-blueprint` re-applies the Authentik config on every `up`; `localai-seed-models` copies default model configs into the models volume. |

## Files

```
docker-compose.yml      the production stack
.env.example            all settings (copy to .env)
config/                 component configuration, mounted into the containers
  apache/                 example vhost for the host's Apache
  authentik/              Authentik blueprint: LDAP source, OIDC app for LocalAI, login policy
  ca/                     optional extra CA certificates for LocalAI (internal CA)
  localai/                default model configs and the decision models installed on start
  postgres/               database init (creates the LocalAI database)
  traefik/                Traefik config and routes (endpoint blocking, rate limit)
scripts/                gen-secrets.sh (fills .env), smoke.sh (post-deploy test)
dev/                    local development only, see dev/README.md
```

Day to day you only touch `.env`, and occasionally the model configs in `config/localai/`.

## Setup

Prerequisites:
- Docker with the NVIDIA container toolkit
- Apache ≥ 2.4.47 on the host, with a certificate covering `ai.<domain>` and `auth.<domain>`; DNS for both names
  pointing at the server
- the connection details of your LDAP/AD (see
  [Connecting your company LDAP / Active Directory](#connecting-your-company-ldap--active-directory))

**1. Configure and start the stack**

```bash
cp .env.example .env
scripts/gen-secrets.sh        # fills the empty secrets in .env
$EDITOR .env                  # DOMAIN, LDAP_*, LOCALAI_ADMIN_EMAIL, image tags, TRAEFIK_HTTP_PORT if 8081 is taken
docker compose up -d
```

**2. Add the Apache vhosts**

Copy [`config/apache/embedder-stack.conf.example`](config/apache/embedder-stack.conf.example), replace the domain,
certificate paths and (if changed) the port, then:

```bash
sudo a2enmod ssl proxy proxy_http headers rewrite
sudo cp config/apache/embedder-stack.conf.example /etc/apache2/sites-available/embedder-stack.conf   # then edit
sudo a2ensite embedder-stack && sudo apachectl configtest && sudo systemctl reload apache2
```

Apache only forwards both hostnames to Traefik. All stack-specific rules (blocked endpoints, rate limits, routing)
stay in Traefik. What the vhost must do (all in the example):

- **`ProxyPreserveHost On`**: Traefik routes by host name, and Authentik/LocalAI build their URLs from it.
- **`RequestHeader set X-Forwarded-Proto "https"`**: tells the stack the public URL is https. Without it, logins
  redirect to `http://` URLs and fail.
- **`upgrade=websocket`** on `ProxyPass`: the Authentik UI and LocalAI's live logs use WebSockets.
- **`ProxyTimeout 600`**: the first request to a model includes loading it, which can take minutes.

**3. Make sure containers can reach Apache.** LocalAI fetches Authentik's login configuration from
`https://auth.<domain>` itself, and that request goes **through Apache** (the container resolves `auth.<domain>` to
the host). So Apache must listen on all interfaces (`*:443`, not only the public IP), and a host firewall (e.g. ufw)
must allow Docker containers to reach port 443 on the host. A certificate from a public CA works out of the box; for
one from an internal CA, put the CA certificate into `config/ca/`.

**4. First start.** LocalAI downloads its backends (~15 GB) and the preloaded decision models. That can take a while.
`docker compose ps` shows `localai` as healthy once the API is up.

## Connecting your company LDAP / Active Directory

The stack does not run its own user directory. Users and groups come from your **existing** LDAP or Active Directory
server, and connecting it takes only a few lines in `.env`. Nothing has to be installed or changed on the LDAP side
except, possibly, a service account and a group (see the checklist below).

**1. Always required**

```bash
LDAP_URL=ldaps://ldap.yourcompany.com:636                          # where the LDAP server is
LDAP_BIND_DN=cn=svc-embedder,ou=services,dc=yourcompany,dc=com    # service account the stack logs in with
LDAP_BIND_PASSWORD=...                                             # its password
LDAP_BASE_DN=dc=yourcompany,dc=com                                 # top of your directory tree
```

The service account only needs **read** access to users and groups. The stack never writes to LDAP.

**2. Usually adjusted**

```bash
LDAP_USER_DN=ou=people          # where users sit below LDAP_BASE_DN (empty = search the whole tree)
LDAP_GROUP_DN=ou=groups         # where groups sit below LDAP_BASE_DN (empty = search the whole tree)
API_USERS_GROUP=ai-api-users    # only members of this group may log in and create API keys
```

`API_USERS_GROUP` must be an existing group in your directory. Either ask for a new group `ai-api-users`, or set an
existing group name here.

**3. Only for Active Directory**

AD names things differently from OpenLDAP. The defaults fit OpenLDAP-style directories; for AD, set these five lines
(they are also in `.env.example`, ready to uncomment):

```bash
LDAP_USER_FILTER=(&(objectClass=user)(!(objectClass=computer)))
LDAP_GROUP_FILTER=(objectClass=group)
LDAP_UNIQUENESS_FIELD=objectSid
LDAP_USERNAME_ATTRIBUTE=sAMAccountName
LDAP_NAME_ATTRIBUTE=displayName
```

**4. Only if your LDAP server uses a certificate from an internal company CA**

With `ldaps://` (or `LDAP_START_TLS=true`), Authentik must trust the server's certificate. If it comes from an internal
CA, this is the one step outside `.env`: in the Authentik admin UI (`https://auth.<domain>/if/admin/`), import the CA
certificate under *System → Certificates*, then select it as *TLS Verification Certificate* on the LDAP source
(*Directory → Federation & Social login → LDAP directory*).

**What to ask your LDAP admin for**

- [ ] Server address and port, and whether it uses `ldaps://` or StartTLS (plus the CA certificate if it is internal)
- [ ] Is it Active Directory or OpenLDAP-style?
- [ ] A read-only service account: its DN and password
- [ ] The base DN, and where users and groups live (OUs)
- [ ] A group for API users (e.g. `ai-api-users`), with the right people in it
- [ ] The email address of the person who should be LocalAI admin (`LOCALAI_ADMIN_EMAIL`)

**How changes in LDAP reach the stack**

- **Immediately (checked live at login):** password changes, locked or disabled accounts.
- **At the next sync (every 2 h):** new users, removed users, and group membership changes. To pick them up sooner,
  open the LDAP source in the Authentik admin UI and press *Run sync*, or shorten the schedule there.

After `docker compose up -d`, check the connection in the Authentik admin UI: the LDAP source shows its connection
status and the result of the last sync, and synced users appear under *Directory → Users*.

## Log in and create an API key

1. Open `https://ai.<domain>` and choose **Sign in with SSO**. Log in with directory credentials.
2. In LocalAI, open **API keys**, then create a key. It is shown once. Keys can be paused or revoked.
3. `LOCALAI_ADMIN_EMAIL` becomes a LocalAI **admin** and can install models and see per-user usage. Everyone else
   gets the `user` role, which allows inference only.

> Note: the **first** user ever to log in also becomes admin (LocalAI default). Log in as the admin first.

## Use the API

```python
from openai import OpenAI
client = OpenAI(base_url="https://ai.example.org/v1", api_key="<your key>")
client.embeddings.create(model="bge-m3", input=["hello", "world"])
```

```bash
KEY=<your key>; BASE=https://ai.example.org
curl $BASE/v1/rerank -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{
  "model": "bge-reranker-v2-m3", "query": "refund for broken order",
  "documents": ["shipping times", "refunds for damaged goods", "password reset"], "top_n": 2}'

curl $BASE/v1/systemone -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{
  "model": "laya-llama-cpp",
  "state": "My order arrived broken and I want my money back.",
  "questions": {
    "team":   {"type": "choice", "instructions": "Which team handles this?",
               "criteria": {"billing": "Payments and refunds", "shipping": "Delivery and damaged goods"}},
    "refund": {"type": "noul",   "instructions": "The customer asks for a refund"},
    "urgency":{"type": "score",  "instructions": "How urgent?", "criteria": ["low", "medium", "high"]}}}'
```

`GET /v1/models` lists what is installed.

## Models

| Kind | Configured in | Add another |
|---|---|---|
| Embeddings | `config/localai/models/bge-m3.yaml` (`backend: transformers`, `type: SentenceTransformer`) | Copy the file, set any HF sentence-transformers repo, `docker compose up -d`. GGUF embedders: `backend: llama-cpp`. |
| Reranker | `config/localai/models/bge-reranker-v2-m3.yaml` (`backend: rerankers`) | Any HF cross-encoder via `parameters.model`. |
| Decisions | `config/localai/preload/server.yaml` (gallery ids, installed on start) | Gallery entries tagged `decisions`, or the admin UI → Models. |

Decision models only work if their **architecture is supported** by a LocalAI backend:

- `llama-cpp` (default here, runs on any NVIDIA GPU and on CPU): `laya-llama-cpp`, `kev-4b-llama-cpp`,
  `lev-llama-cpp`, `nimble-9b-v3-llama-cpp` (CC-BY-NC), `julia-1-llama-cpp`.
- `vllm-cpp` (alpha): `tev1-4b/0.8b`, `gliner25-decide`, `kev-0.8b`, `nimble-9b`, `clm-v0.1-8b`. Its CUDA build is
  **Blackwell-only** (RTX 50xx / RTX PRO 6000 / B200). On those hosts set `LOCALAI_TAG=master-gpu-nvidia-cuda-13`,
  `LOCALAI_BACKENDS=cuda13-…,cuda13-vllm-cpp-development` and uncomment the entries in `config/localai/preload/server.yaml`.
  Other GPUs need `cpu-vllm-cpp-development` (or the Vulkan build).

Configs written by hand need the right backend, `known_usecases`, and for some models extra engine settings. Tev1 for
example needs `backend: vllm-cpp`, `known_usecases: [decisions]`, `engine_args.hf_overrides.architectures: [Tev1Model]`
and `context_size: 2048`. The gallery entries are good references. The Hugging Face import in the UI often guesses
`vllm` + `chat` for non-chat models; check both fields.

Files in `config/localai/models/` are **defaults**. On `up`, the `localai-seed-models` service copies each one into the models
volume, but only if it isn't there yet. After that, LocalAI owns the copy: edit it in the UI (admin → Models → Edit).
Changing the repo file later doesn't overwrite it. To reset a model to the repo version, delete it in the UI, then
`docker compose up -d` again.

### Lifecycle (like Ollama)

Models load on their first request. After `LOCALAI_WATCHDOG_IDLE_TIMEOUT` with no use they are unloaded. At most
`LOCALAI_MAX_ACTIVE_BACKENDS` models stay resident, and the least recently used one is evicted first.

Size `LOCALAI_MAX_ACTIVE_BACKENDS` to the GPU memory: the limit counts models, not memory. The default of 4 suits a
24 GB+ GPU with the default models (bge-m3 and the reranker take ~2.3 GB each, Kev-4B ~3 GB, Laya ~0.5 GB). If it is
set too high, loading another model fails with `cudaMalloc failed: out of memory`.

## Security notes

- Endpoints are blocked in **two places**. No chat models are installed, and Traefik's `ai-blocked` router answers 403
  for chat, completions, images, audio and similar routes. This matters because some decision models (Tev1) can also chat.
- LocalAI per-user feature flags (Admin → Users) can switch off features per user as well.
- API keys are stored HMAC-hashed in Postgres. Users can pause or revoke their own keys, and admins can revoke any key.
- Removing someone from `API_USERS_GROUP` stops new logins after the next sync. Their **existing API keys keep
  working** until they expire (`LOCALAI_DEFAULT_API_KEY_EXPIRY`, default 180d) or an admin disables the user in
  LocalAI. Keys of disabled users are rejected. LocalAI has no SCIM/deprovisioning hook.
- `LOCALAI_TAG` is a moving `master` tag, because decisions are not in a release yet. Pin a digest for production.
- The Authentik admin UI is at `https://auth.<domain>/if/admin/` (user `akadmin`, `AUTHENTIK_BOOTSTRAP_PASSWORD`).

## Backups

The `postgres` volume holds users, API keys and all configuration. Back it up together with `localai-data`, which holds
the secret used to hash API keys (existing keys stop working without it). Models and backends can be downloaded again.

## Smoke test

```bash
API_KEY=<key> scripts/smoke.sh       # without API_KEY only the unauthenticated checks run
DECISION_MODELS="laya-llama-cpp lev-llama-cpp" API_KEY=<key> scripts/smoke.sh
CURL_CA_BUNDLE=config/ca/company-ca.crt API_KEY=<key> scripts/smoke.sh     # internal CA
```

`smoke.sh` checks: 401 without a key or with a bad key, 403 for chat/completions, 200 + payloads for embeddings, rerank and
each decision model, and 403 when a user key tries to install a model.

## Troubleshooting

- **Decision model fails with `check_tensor_dims` / `wrong number of tensors`**: the release `llama-cpp` backend is
  installed instead of the master one. Use `*-llama-cpp-development` in `LOCALAI_BACKENDS`, then remove the old backend
  (`docker compose exec localai rm -rf /backends/cuda12-llama-cpp`) and restart.
- **`no backend found with name "rerankers"`**: name concrete variants (`cuda12-rerankers`) in `LOCALAI_BACKENDS`.
  The generic names do not resolve for every GPU flavour.
- **`no kernel image is available`** for a `vllm-cpp` model: the CUDA build got installed on a non-Blackwell GPU.
  Install `cpu-vllm-cpp-development` instead.
- **Model fails, then `load is in cooldown after a recent failure`**: LocalAI waits longer after each failed load.
  Wait, or `docker compose restart localai`, after fixing the config.
- **SSO callback error `invalid_request`**: the Authentik provider needs `grant_types: [authorization_code, ...]`
  (already in the blueprint). Check the Authentik server logs.
- **Users can't log in although they exist in LDAP**: check they are in `API_USERS_GROUP` and that a sync ran since
  (Authentik admin UI → the LDAP source shows the last sync and its errors).
- **Login ends on an `http://` URL or fails with a redirect/issuer error**: the Apache vhost is missing
  `RequestHeader set X-Forwarded-Proto "https"` or `ProxyPreserveHost On`.
- **`localai` logs OIDC/discovery errors, login doesn't start**: LocalAI can't reach `https://auth.<domain>` through
  Apache. Test with
  `docker compose exec localai curl -sS https://auth.<domain>/application/o/localai/.well-known/openid-configuration`.
  Check that Apache listens on `*:443` (not only the public IP), the host firewall, and for an internal CA `config/ca/`.
- **Model fails with `cudaMalloc failed: out of memory`**: too many models loaded at once for the GPU. Lower
  `LOCALAI_MAX_ACTIVE_BACKENDS` (see [Lifecycle](#lifecycle-like-ollama)).
- **`localai` stays in `starting` for a long time** on first boot: it is downloading backends and models
  (`docker compose logs -f localai`).
