#!/usr/bin/env python3
"""One-shot OAuth helper for the enso-dm-bridge app.

The bridge reads Hank's *own* DMs, so it needs a Slack **user token** (xoxp-)
that Hank authorizes in his browser. Only he can grant it; this script just
builds the consent URL and exchanges the short-lived code Slack hands back.

Flow (no public web server needed):

  1. On the VM:   python3 oauth.py url
     -> prints the authorize URL. Send it to Hank.

  2. Hank opens it, approves. His browser lands on the redirect
     (https://localhost/dm-bridge/oauth?code=...&state=...). The page won't
     load — that's fine — the `code` is right there in the address bar.
     He copies the whole URL (or just the code=... value) back to you.
     The code is valid for ~10 minutes and can be exchanged from anywhere.

  3. On the VM:   python3 oauth.py exchange '<pasted url or code>'
     -> exchanges it and appends DM_BRIDGE_USER_TOKEN to the env file
        (~/.config/enso-agent/dm-bridge.env, mode 600). The token is never
        printed.

App credentials come from the env (DM_BRIDGE_CLIENT_ID / DM_BRIDGE_CLIENT_SECRET),
which you set once from the app's Basic Information page. They are never logged.
"""
import os
import sys
import json
import stat
import urllib.parse
import urllib.request
import urllib.error

REDIRECT_URI = "https://localhost/dm-bridge/oauth"
# User scopes must match the manifest exactly.
USER_SCOPES = "im:read,im:history,mpim:read,mpim:history,users:read"
ENV_PATH = os.path.expanduser(
    os.environ.get("DM_BRIDGE_ENV", "~/.config/enso-agent/dm-bridge.env")
)
STATE = "enso-dm-bridge"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def need(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        die(f"{name} is not set (export it or put it in {ENV_PATH})")
    return val


def build_url() -> str:
    client_id = need("DM_BRIDGE_CLIENT_ID")
    params = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "user_scope": USER_SCOPES,
            "scope": "",  # no bot scopes; user token only
            "redirect_uri": REDIRECT_URI,
            "state": STATE,
        }
    )
    return f"https://slack.com/oauth/v2/authorize?{params}"


def extract_code(blob: str) -> str:
    blob = blob.strip()
    if blob.startswith("http"):
        q = urllib.parse.urlparse(blob).query
        code = urllib.parse.parse_qs(q).get("code", [""])[0]
        return code
    # bare code, possibly "code=xxx"
    if blob.startswith("code="):
        return blob[len("code="):]
    return blob


def exchange(code: str) -> None:
    client_id = need("DM_BRIDGE_CLIENT_ID")
    client_secret = need("DM_BRIDGE_CLIENT_SECRET")
    if not code:
        die("no code found in the value you pasted")
    data = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "code": code,
            "redirect_uri": REDIRECT_URI,
        }
    ).encode()
    req = urllib.request.Request("https://slack.com/api/oauth.v2.access", data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        die(f"token exchange request failed: {exc}")
    if not payload.get("ok"):
        die(f"Slack refused the exchange: {payload.get('error', 'unknown error')}")
    user = payload.get("authed_user") or {}
    token = user.get("access_token", "")
    if not token.startswith("xoxp-"):
        die("Slack did not return a user token (xoxp-); check the app has user scopes, not bot scopes")
    _append_token(token, user.get("id", "?"))
    print(f"ok: stored user token for {user.get('id', '?')} in {ENV_PATH} (value not shown)")
    print("next: set DM_BRIDGE_OWNER_ID to that same user id, then start the timer.")


def _append_token(token: str, uid: str) -> None:
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    lines = []
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH) as fh:
            lines = [ln for ln in fh.read().splitlines() if not ln.startswith("DM_BRIDGE_USER_TOKEN=")]
    lines.append(f"DM_BRIDGE_USER_TOKEN={token}")
    with open(ENV_PATH, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(ENV_PATH, stat.S_IRUSR | stat.S_IWUSR)  # 600


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("url", "exchange"):
        print(__doc__)
        print("usage: oauth.py url | oauth.py exchange '<redirect url or code>'")
        sys.exit(2)
    if sys.argv[1] == "url":
        print(build_url())
    else:
        if len(sys.argv) < 3:
            die("exchange needs the redirect URL or code Hank sent back")
        exchange(extract_code(sys.argv[2]))


if __name__ == "__main__":
    main()
