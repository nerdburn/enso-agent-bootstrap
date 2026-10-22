#!/usr/bin/env python3
"""enso-dm-bridge: heads-up for your own unread Slack DMs.

Reads the owner's direct + group DMs with the owner's **user token** (xoxp-),
finds messages that arrived since the last run, and posts a single private
digest to the owner via the agent's bot token (xoxb-). Nothing is stored except
a per-conversation "last seen" timestamp cursor.

This only ever touches the owner's own conversations — the ones a person reads
in their own Slack client. It is a triage aid for that one person's inbox, run
with that person's own authorization.

Env (loaded from ~/.config/enso-agent/dm-bridge.env by the systemd unit):
  DM_BRIDGE_USER_TOKEN       xoxp- token the owner authorized (see oauth.py)   [required]
  DM_BRIDGE_OWNER_ID         the owner's Slack user id, e.g. U0XXXXXXXXX        [required]
  DM_BRIDGE_NOTIFY_TOKEN     xoxb- bot token used to DM the heads-up       [required]
  DM_BRIDGE_VIP_IDS          comma-sep user ids to flag as priority        [optional]
  DM_BRIDGE_KEYWORDS         comma-sep words that mark a msg urgent         [optional]
  DM_BRIDGE_DIGEST_ONLY      "1" (default): never include message text,
                             only who/where/count. "0": include a short
                             preview snippet of each message.             [optional]
  DM_BRIDGE_STATE            cursor file (default ~/.config/enso-agent/dm-bridge-state.json)
"""
import os
import sys
import json
import time
import urllib.parse
import urllib.request
import urllib.error

API = "https://slack.com/api/"
STATE_PATH = os.path.expanduser(
    os.environ.get("DM_BRIDGE_STATE", "~/.config/enso-agent/dm-bridge-state.json")
)


def log(msg: str) -> None:
    print(f"[dm-bridge] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[dm-bridge] error: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def env(name: str, required: bool = False, default: str = "") -> str:
    val = os.environ.get(name, default).strip()
    if required and not val:
        die(f"{name} is not set")
    return val


def slack(method: str, token: str, **params):
    """GET/POST to the Slack Web API. Tokens go in the Authorization header,
    never in the URL or logs."""
    url = API + method
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if method in ("conversations.open", "chat.postMessage"):
        data = json.dumps(params).encode()
        headers["Content-Type"] = "application/json; charset=utf-8"
    else:
        if params:
            url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=data, headers=headers)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code == 429:  # rate limited
                wait = int(exc.headers.get("Retry-After", "2"))
                time.sleep(wait + 1)
                continue
            die(f"{method} HTTP {exc.code}")
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            if attempt < 3:
                time.sleep(2)
                continue
            die(f"{method} failed: {exc}")
    return {}


def load_state() -> dict:
    try:
        with open(STATE_PATH) as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_PATH)


def list_dms(user_token: str) -> list[dict]:
    convs, cursor = [], ""
    while True:
        params = {"types": "im,mpim", "exclude_archived": "true", "limit": "200"}
        if cursor:
            params["cursor"] = cursor
        payload = slack("conversations.list", user_token, **params)
        if not payload.get("ok"):
            die(f"conversations.list: {payload.get('error', 'unknown error')}")
        convs.extend(payload.get("channels", []))
        cursor = (payload.get("response_metadata") or {}).get("next_cursor", "")
        if not cursor:
            return convs


def name_cache(user_token: str):
    cache: dict[str, str] = {}

    def resolve(uid: str) -> str:
        if not uid:
            return "someone"
        if uid not in cache:
            info = slack("users.info", user_token, user=uid)
            prof = (info.get("user") or {}).get("profile") or {} if info.get("ok") else {}
            cache[uid] = (
                prof.get("display_name")
                or prof.get("real_name")
                or (info.get("user") or {}).get("name")
                or uid
            )
        return cache[uid]

    return resolve


def main() -> None:
    user_token = env("DM_BRIDGE_USER_TOKEN", required=True)
    owner = env("DM_BRIDGE_OWNER_ID", required=True)
    notify_token = env("DM_BRIDGE_NOTIFY_TOKEN", required=True)
    vips = {x.strip() for x in env("DM_BRIDGE_VIP_IDS").split(",") if x.strip()}
    keywords = [w.strip().lower() for w in env("DM_BRIDGE_KEYWORDS").split(",") if w.strip()]
    digest_only = env("DM_BRIDGE_DIGEST_ONLY", default="1") != "0"

    if not user_token.startswith("xoxp-"):
        die("DM_BRIDGE_USER_TOKEN must be a user token (xoxp-); run oauth.py first")

    state = load_state()
    resolve = name_cache(user_token)
    first_run = not state  # don't dump full history on the very first run

    items = []  # one entry per conversation with new incoming messages
    for conv in list_dms(user_token):
        cid = conv["id"]
        last = state.get(cid)
        hist_params = {"channel": cid, "limit": "50"}
        if last:
            hist_params["oldest"] = last
        hist = slack("conversations.history", user_token, **hist_params)
        if not hist.get("ok"):
            # a conversation we can't read (e.g. left) — skip quietly
            continue
        msgs = [
            m
            for m in hist.get("messages", [])
            if m.get("ts") != last
            and m.get("user") != owner       # ignore the owner's own messages
            and m.get("type") == "message"
            and not m.get("subtype")         # skip joins/edits/system
        ]
        # advance cursor regardless, so we never re-report
        newest = hist.get("messages", [{}])[0].get("ts") if hist.get("messages") else last
        if newest:
            state[cid] = newest
        if first_run or not msgs:
            continue

        senders = sorted({m.get("user") for m in msgs if m.get("user")})
        who = ", ".join(resolve(s) for s in senders) or "someone"
        is_mpim = conv.get("is_mpim")
        priority = bool(vips & set(senders)) or any(
            kw in (m.get("text", "").lower()) for m in msgs for kw in keywords
        )
        line = f"{'👥' if is_mpim else '💬'} *{who}* — {len(msgs)} new"
        if priority:
            line = "⭐ " + line
        if not digest_only:
            snippet = (msgs[-1].get("text", "") or "").replace("\n", " ")
            if len(snippet) > 140:
                snippet = snippet[:140] + "…"
            if snippet:
                line += f"\n    ↳ {snippet}"
        items.append((priority, line))

    save_state(state)

    if first_run:
        log("first run: recorded cursors, no digest sent")
        return
    if not items:
        log("no new DMs")
        return

    items.sort(key=lambda x: (not x[0]))  # priority first
    body = "*You have new direct messages:*\n" + "\n".join(line for _, line in items)

    opened = slack("conversations.open", notify_token, users=owner)
    if not opened.get("ok"):
        die(f"conversations.open to owner failed: {opened.get('error', 'unknown error')}")
    channel = opened["channel"]["id"]
    posted = slack("chat.postMessage", notify_token, channel=channel, text=body, unfurl_links=False)
    if not posted.get("ok"):
        die(f"chat.postMessage failed: {posted.get('error', 'unknown error')}")
    log(f"sent digest: {len(items)} conversation(s)")


if __name__ == "__main__":
    main()
