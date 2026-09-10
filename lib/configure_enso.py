#!/usr/bin/env python3
"""Non-interactive equivalent of `enso setup` for a fresh Slack installation.

Runs on the VM with enso's own venv interpreter so it can reuse enso's setup
internals (config defaults, managed-workspace scaffolding, baseline commit,
completion marker) exactly as the interactive wizard does.  It only ever acts
on a *fresh or interrupted* installation; a completed setup is left untouched.

Inputs come from the environment (install.sh exports them from the .conf):
  AGENT_NAME, SLACK_MODE, SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_OWNER_IDS,
  NOTIFY_CHANNEL, ENSO_SLACK_API_BASE_URL (gateway mode only).
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

GATEWAY_PLACEHOLDER_BOT = "xoxb-injected-by-exe-dev-gateway"
GATEWAY_PLACEHOLDER_APP = "xapp-injected-by-exe-dev-gateway"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def split_ids(raw: str) -> list[str]:
    return [p for p in re.split(r"[\s,]+", raw) if p]


def slack_auth_test(mode: str, bot_token: str, gateway: str) -> dict:
    """Return Slack's auth.test payload for the configured credentials."""
    if mode == "gateway":
        url = gateway.rstrip("/") + "/auth.test"
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
    else:
        url = "https://slack.com/api/auth.test"
        headers = {
            "Authorization": f"Bearer {bot_token}",
            "Content-Type": "application/x-www-form-urlencoded",
        }
    req = urllib.request.Request(url, data=b"", headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        die(f"Slack auth.test failed ({url}): {exc}")
    if not payload.get("ok"):
        hint = (
            " — is the exe.dev Slack Bot integration created and attached to this VM?"
            if mode == "gateway" else ""
        )
        die(f"Slack rejected the bot token: {payload.get('error', 'unknown error')}{hint}")
    for key in ("team_id", "user_id"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            die(f"Slack auth.test did not return {key}")
    return payload


def main() -> None:
    try:
        from enso.cli import (
            _ensure_default_execution_config,
            _ensure_repository_or_exit,
            _finalize_setup_or_exit,
        )
        from enso.config import (
            CONFIG_FILE,
            SetupState,
            config_lock,
            load_config,
            resolve_providers,
            setup_state,
        )
    except ImportError as exc:  # enso internals moved; fail loudly, not silently
        die(
            "could not import enso setup internals — this bootstrap targets enso 2.x "
            f"({exc}). Pin ENSO_REF to a 2.x release or update configure_enso.py."
        )

    mode = env("SLACK_MODE", "direct")
    if mode not in ("direct", "gateway"):
        die("SLACK_MODE must be 'direct' or 'gateway'")
    bot_token = env("SLACK_BOT_TOKEN")
    app_token = env("SLACK_APP_TOKEN")
    gateway = env("ENSO_SLACK_API_BASE_URL")
    owners = split_ids(env("SLACK_OWNER_IDS"))
    notify = env("NOTIFY_CHANNEL")

    if mode == "direct":
        if not bot_token.startswith("xoxb-"):
            die("SLACK_BOT_TOKEN must be set (xoxb-...) in direct mode")
        if not app_token.startswith("xapp-"):
            die("SLACK_APP_TOKEN must be set (xapp-...) in direct mode")
    else:
        if not gateway.startswith("https://"):
            die("ENSO_SLACK_API_BASE_URL must be set in gateway mode")
        bot_token = bot_token or GATEWAY_PLACEHOLDER_BOT
        app_token = app_token or GATEWAY_PLACEHOLDER_APP
    if not owners:
        die("SLACK_OWNER_IDS must list at least one Slack user ID (U...)")
    for owner in owners:
        if not re.fullmatch(r"[UW][A-Z0-9]{6,}", owner):
            die(f"'{owner}' does not look like a Slack user ID (e.g. U02FB3JNB)")

    if env("SKIP_SLACK_VALIDATION") == "1":
        auth = {"team_id": "T00000000", "user_id": "U00000000", "user": "test"}
    else:
        auth = slack_auth_test(mode, bot_token, gateway)
    print(f"    [enso] Slack bot '{auth.get('user')}' in team {auth['team_id']}")

    with config_lock():
        config = load_config(allow_missing=True)
        state = setup_state(config)
        if state is not SetupState.INCOMPLETE:
            print(
                f"    [enso] {CONFIG_FILE} already holds a {state.value} setup; "
                "leaving configuration unchanged"
            )
            return

        config["providers"] = resolve_providers()
        workspace = _ensure_default_execution_config(config)
        config["transport"] = "slack"
        config.setdefault("transports", {})["slack"] = {
            "bot_token": bot_token,
            "app_token": app_token,
            "account_id": auth["team_id"],
            "bot_user_id": auth["user_id"],
            "notify_channel": notify,
            "rich_messages": True,
            "persistent_surfaces": True,
            "channel_defaults": {
                "mention_required": True,
                "thread_mention_required": True,
            },
            "dms": {owner: {"workspace": workspace} for owner in owners},
            "channels": {},
        }
        _ensure_repository_or_exit()
        # Saves the incomplete marker, seeds ~/.enso content, records the
        # baseline commit, then writes setup.completed_at.
        _finalize_setup_or_exit(config)

    print(f"    [enso] wrote {CONFIG_FILE} and seeded ~/.enso (workspace '{workspace}')")


if __name__ == "__main__":
    main()
