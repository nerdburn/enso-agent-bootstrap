#!/usr/bin/env python3
"""Read a pre-0.4 enso home (the enso 2.x fork, or older) for install.sh --migrate.

Prints shell assignments (`KEY='value'`) for the values a fresh 0.4 install
needs and the conf left blank: Slack tokens, owner IDs, the channel workspace
and its channel IDs, the lore context, and the notify target. Values the conf
already sets win; nothing here is written anywhere else. Exits non-zero, with
the reason, when the home cannot be migrated automatically (several channel
workspaces, no usable tokens), before install.sh stops anything.

Usage: read_legacy.py <old-home>   (environment: the conf's values)
"""

from __future__ import annotations

import json
import os
import shlex
import sys

PLACEHOLDER = "injected-by-exe-dev-gateway"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def usable(token: str, prefix: str) -> bool:
    return token.startswith(prefix) and PLACEHOLDER not in token


def main() -> None:
    old = sys.argv[1]
    path = os.path.join(old, "config.json")
    if not os.path.isfile(path):
        die(f"no config.json in {old}; nothing to migrate")
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    if cfg.get("version") == 2:
        die(f"{path} is already an enso 0.4 config; run install.sh without --migrate")

    slack = (cfg.get("transports") or {}).get("slack") or cfg.get("slack") or {}
    out: dict[str, str] = {}

    bot, app = slack.get("bot_token", ""), slack.get("app_token", "")
    if not os.environ.get("SLACK_BOT_TOKEN") and usable(bot, "xoxb-"):
        out["SLACK_BOT_TOKEN"] = bot
    if not os.environ.get("SLACK_APP_TOKEN") and usable(app, "xapp-"):
        out["SLACK_APP_TOKEN"] = app
    if not (os.environ.get("SLACK_BOT_TOKEN") or "SLACK_BOT_TOKEN" in out) or not (
        os.environ.get("SLACK_APP_TOKEN") or "SLACK_APP_TOKEN" in out
    ):
        die("the old home only has exe.dev gateway placeholders for the Slack tokens, and enso 0.4 needs the real "
            "ones. Put SLACK_BOT_TOKEN (OAuth & Permissions → Bot User OAuth Token) and SLACK_APP_TOKEN (Basic "
            "Information → App-Level Tokens) from this agent's Slack app in the conf, then re-run. Nothing was changed.")

    # Owners: enso 2.x `dms`, 1.x `access.allowed_users`.
    owners = list((slack.get("dms") or {}).keys()) or list(((cfg.get("access") or {}).get("allowed_users")) or [])
    if not os.environ.get("SLACK_OWNER_IDS") and owners:
        out["SLACK_OWNER_IDS"] = " ".join(owners)

    # Channel routes → one channel workspace.
    routes = slack.get("channels") or {}
    by_ws: dict[str, list[str]] = {}
    for cid, route in routes.items():
        ws = route.get("workspace") if isinstance(route, dict) else None
        if ws and ws != "default":
            by_ws.setdefault(ws, []).append(cid)
    if len(by_ws) > 1 and not os.environ.get("CHANNEL_WORKSPACE"):
        die(f"the old home routes channels to several workspaces ({', '.join(by_ws)}); this bootstrap makes one. "
            "Migrate it by hand, or set CHANNEL_WORKSPACE/CHANNELS in the conf to choose.")
    if by_ws and not os.environ.get("CHANNEL_WORKSPACE"):
        ws, ids = next(iter(by_ws.items()))
        out["CHANNEL_WORKSPACE"] = ws
        if not os.environ.get("CHANNELS"):
            out["CHANNELS"] = " ".join(ids)

    # lore context: the fork's policies carried `lore mcp --context X` in claude/mcp.json.
    if not os.environ.get("LORE_CONTEXT"):
        for policy in (cfg.get("policies") or {}).values():
            pdir = os.path.expanduser(str(policy.get("policy_dir") or ""))
            mcp = os.path.join(pdir, "claude", "mcp.json")
            if pdir and os.path.isfile(mcp):
                with open(mcp, encoding="utf-8") as fh:
                    args = ((json.load(fh).get("mcpServers") or {}).get("lore") or {}).get("args") or []
                if "--context" in args and args.index("--context") + 1 < len(args):
                    out["LORE_CONTEXT"] = args[args.index("--context") + 1]
                    break

    notify = slack.get("notify_channel") or slack.get("notify") or ""
    if not os.environ.get("NOTIFY_CHANNEL") and notify:
        out["NOTIFY_CHANNEL"] = notify

    for key, value in out.items():
        print(f"{key}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
