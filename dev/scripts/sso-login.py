#!/usr/bin/env python3
"""Headless SSO login: LocalAI -> Authentik (LDAP password) -> LocalAI session, then create an API key.

Used for automated testing of the auth chain without a browser:
    dev/scripts/sso-login.py alice "$LDAP_SEED_USER_PASSWORD"            # prints a new API key
    dev/scripts/sso-login.py bob   "$LDAP_SEED_USER_PASSWORD" --expect-denied
Uses http:// (dev mode) by default; set SCHEME=https to test an HTTPS deployment.
Requires: python3 with `requests`.
"""
import argparse
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import requests

ROOT = Path(__file__).resolve().parent.parent.parent


def env_value(key: str) -> str:
    if key in os.environ:
        return os.environ[key]
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1]
    raise SystemExit(f"{key} not set")


def run_flow(s: requests.Session, auth_base: str, flow_url: str, username: str, password: str) -> str:
    """Drives an Authentik flow through its executor API; returns the final redirect target."""
    u = urlparse(flow_url)
    slug = u.path.rstrip("/").split("/")[-1]
    query = parse_qs(u.query).get("query", [u.query])[0] if "query=" in u.query else u.query
    api = f"{auth_base}/api/v3/flows/executor/{slug}/"
    params = {"query": query}
    challenge = s.get(api, params=params).json()
    for _ in range(10):
        component = challenge.get("component")
        if component == "xak-flow-redirect":
            return challenge["to"]
        if component == "ak-stage-identification":
            challenge = s.post(api, params=params, json={"component": component, "uid_field": username}).json()
        elif component == "ak-stage-password":
            challenge = s.post(api, params=params, json={"component": component, "password": password}).json()
        elif component == "ak-stage-access-denied":
            raise PermissionError(challenge.get("error_message", "access denied"))
        elif component == "ak-stage-consent":
            challenge = s.post(api, params=params, json={"component": component, "token": challenge["token"]}).json()
        else:
            raise RuntimeError(f"unhandled flow stage: {challenge}")
    raise RuntimeError("flow did not finish")


def follow(s: requests.Session, url: str, auth_base: str, username: str, password: str) -> requests.Response:
    """Follows redirects, executing Authentik flows (/if/flow/...) via the API when one is hit."""
    for _ in range(20):
        r = s.get(url, allow_redirects=False)
        if r.status_code in (301, 302, 303, 307, 308):
            url = requests.compat.urljoin(url, r.headers["Location"])
            continue
        if "/if/flow/" in url:
            url = requests.compat.urljoin(auth_base + "/", run_flow(s, auth_base, url, username, password))
            continue
        return r
    raise RuntimeError("too many redirects")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("username")
    ap.add_argument("password")
    ap.add_argument("--expect-denied", action="store_true")
    ap.add_argument("--key-name", default="sso-login-script")
    args = ap.parse_args()

    domain = env_value("DOMAIN")
    scheme = os.environ.get("SCHEME", "http")
    ai, auth = f"{scheme}://ai.{domain}", f"{scheme}://auth.{domain}"
    s = requests.Session()
    if scheme == "https" and (ROOT / "certs/ca/ca.crt").exists():
        s.verify = str(ROOT / "certs/ca/ca.crt")

    try:
        follow(s, f"{ai}/api/auth/oidc/login", auth, args.username, args.password)
        denied = None
    except PermissionError as e:
        denied = str(e)

    # Authentik may also deny by rendering an access-denied page on /authorize
    # (no redirect back), so the LocalAI session is the real test.
    user = s.get(f"{ai}/api/auth/status").json().get("user")
    if user is None:
        if args.expect_denied:
            print(f"denied as expected{': ' + denied if denied else ''}")
            return 0
        print(f"login failed{': ' + denied if denied else ''}", file=sys.stderr)
        return 1
    if args.expect_denied:
        print("FAIL: login was expected to be denied", file=sys.stderr)
        return 1

    print(f"logged in: {user['name']} <{user['email']}> role={user['role']}", file=sys.stderr)
    r = s.post(f"{ai}/api/auth/api-keys", json={"name": args.key_name, "expiresIn": "1d"})
    r.raise_for_status()
    print(r.json()["key"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
