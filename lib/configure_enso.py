#!/usr/bin/env python3
"""Non-interactive enso 0.4 configuration for one Slack agent. Idempotent.

Runs on the VM with the system python3 (stdlib only) after `enso init`. It talks
to Slack directly and writes configuration only through enso's own CLI
(`enso config apply` for a fresh home, `enso config set` afterwards), so enso
validates every change.

  1. Tokens: SLACK_BOT_TOKEN / SLACK_APP_TOKEN from the conf, else the ones
     already in config.json. Both are checked (auth.test, apps.connections.open).
  2. Channels: CHANNELS (names or C… ids) resolved to ids; public channels the
     bot is not in are joined (the bootstrap manifest adds channels:join).
     Private channels need a human /invite; the binding is written regardless.
  3. Workspace: CHANNEL_WORKSPACE (default: first channel's name) is created
     with `enso workspace create` and given the house full-access setup, the
     same one abby-agent runs: workspace.json with the project checkout
     (--add-dir), --dangerously-skip-permissions, and a strict MCP config whose
     only server is lore over the exe.dev `lore-mcp` integration.
  4. config.json: a fresh home gets the complete document (DM bindings for
     SLACK_OWNER_IDS → DM_WORKSPACE, default `default`, channel bindings → the workspace, notify = the
     first owner's DM). An existing config.json is never replaced: missing
     bindings are added and changed tokens updated with `enso config set`.

Inputs (environment, exported by install.sh): AGENT_NAME, VM_NAME, ENSO_BIN,
ENSO_HOME, SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_OWNER_IDS, DM_WORKSPACE, NOTIFY_CHANNEL,
CHANNELS, CHANNEL_WORKSPACE, LORE_CONTEXT, LORE_MCP_URL, PROJECT_DIR,
DEFAULT_MODEL, DEFAULT_EFFORT, AGENT_TIMEOUT, WEB_PORT, OPERATOR_NAME,
WORKSPACE_TEMPLATE, REPORT (file collecting summary lines).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CHANNEL_ID_RE = re.compile(r"[CG][A-Z0-9]{6,}")
USER_ID_RE = re.compile(r"[UW][A-Z0-9]{6,}")
WORKSPACE_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
PLACEHOLDER = "injected-by-exe-dev-gateway"  # enso 2.x gateway placeholders; never valid here
SCAFFOLD_MARK = "<!-- What is this workspace for?"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"    [enso] {msg}")


def warn(msg: str) -> None:
    print(f"\033[33m    [enso] ! {msg}\033[0m", file=sys.stderr)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def split_list(raw: str) -> list[str]:
    return [p for p in re.split(r"[\s,]+", raw) if p]


def report(lines: list[str]) -> None:
    path = env("REPORT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.writelines(line + "\n" for line in lines)


def home() -> str:
    return os.path.expanduser(env("ENSO_HOME") or "~/.enso")


# ── enso CLI ───────────────────────────────────────────────────────────────────


def enso(*args: str, stdin: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    cmd = [env("ENSO_BIN") or "enso", *args]
    proc = subprocess.run(cmd, input=stdin, text=True, capture_output=True)
    if check and proc.returncode != 0:
        for line in (proc.stdout + proc.stderr).splitlines():
            if line.strip():
                print(f"        {line}", file=sys.stderr)
        die(f"`enso {' '.join(args[:3])}` exited {proc.returncode}")
    return proc


def enso_json(*args: str, stdin: str | None = None) -> dict:
    proc = enso(*args, "--json", stdin=stdin, check=False)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        payload = {}
    if proc.returncode != 0 or not payload or payload.get("ok") is False:
        for line in (proc.stdout + proc.stderr).splitlines():
            if line.strip():
                print(f"        {line}", file=sys.stderr)
        die(f"`enso {' '.join(args[:3])}` failed")
    return payload


# ── Slack ──────────────────────────────────────────────────────────────────────


def slack(method: str, token: str, **params: str) -> dict:
    req = urllib.request.Request(
        f"https://slack.com/api/{method}",
        data=urllib.parse.urlencode(params).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        die(f"Slack {method} failed: {exc}")
    return {}


def check_tokens(bot: str, app: str) -> dict:
    if not bot.startswith("xoxb-") or PLACEHOLDER in bot:
        die("no usable Slack bot token: set SLACK_BOT_TOKEN (xoxb-…) in the conf. enso 0.4 keeps the "
            "tokens in config.json; the exe.dev gateway placeholders from enso 2.x do not work")
    if not app.startswith("xapp-") or PLACEHOLDER in app:
        die("no usable Slack app token: set SLACK_APP_TOKEN (xapp-…, scope connections:write) in the conf")
    auth = slack("auth.test", bot)
    if not auth.get("ok"):
        die(f"Slack rejected the bot token: {auth.get('error', 'unknown error')}")
    sock = slack("apps.connections.open", app)
    if not sock.get("ok"):
        die(f"Slack rejected the app token: {sock.get('error', 'unknown error')} (needs connections:write)")
    info(f"Slack bot '{auth.get('user')}' ({auth.get('user_id')}) in {auth.get('team')}")
    return auth


def list_channels(bot: str) -> dict[str, dict]:
    found: dict[str, dict] = {}
    cursor = ""
    while True:
        params = {"types": "public_channel,private_channel", "exclude_archived": "true", "limit": "1000"}
        if cursor:
            params["cursor"] = cursor
        payload = slack("conversations.list", bot, **params)
        if not payload.get("ok"):
            die(f"conversations.list: {payload.get('error', 'unknown error')}")
        for ch in payload.get("channels", []):
            found[ch["id"]] = ch
        cursor = (payload.get("response_metadata") or {}).get("next_cursor", "")
        if not cursor:
            return found


def resolve_channels(bot: str, wanted: list[str], agent: str) -> tuple[list[dict], list[str]]:
    visible = list_channels(bot)
    by_name = {ch.get("name", "").lower(): ch for ch in visible.values()}
    resolved: list[dict] = []
    pending: list[str] = []
    for raw in wanted:
        token = raw.lstrip("#")
        if CHANNEL_ID_RE.fullmatch(token):
            ch = visible.get(token)
            if ch is None:
                payload = slack("conversations.info", bot, channel=token)
                if not payload.get("ok"):
                    pending.append(f"{token}: not visible to the bot ({payload.get('error')}); "
                                   f"if it is private, /invite @{agent} there. The binding is in place.")
                    resolved.append({"id": token, "name": token, "is_private": True, "is_member": False})
                    continue
                ch = payload["channel"]
        else:
            ch = by_name.get(token.lower())
            if ch is None:
                pending.append(f"#{token}: no channel by that name is visible to the bot. Check the spelling; "
                               f"if it is private, /invite @{agent} to it and re-run install.sh.")
                continue
        resolved.append({"id": ch["id"], "name": ch.get("name", ch["id"]),
                         "is_private": bool(ch.get("is_private")), "is_member": bool(ch.get("is_member"))})
    for ch in resolved:
        if ch["is_member"]:
            continue
        if ch["is_private"]:
            if ch["name"] != ch["id"]:
                pending.append(f"#{ch['name']} ({ch['id']}) is private: /invite @{agent} there. The binding is in place.")
            continue
        joined = slack("conversations.join", bot, channel=ch["id"])
        if joined.get("ok"):
            ch["is_member"] = True
            info(f"joined #{ch['name']} ({ch['id']})")
        else:
            pending.append(f"#{ch['name']} ({ch['id']}): could not join ({joined.get('error')}); "
                           f"/invite @{agent} there. The binding is in place.")
    return resolved, pending


def owner_dm(bot: str, owner: str) -> str:
    payload = slack("conversations.open", bot, users=owner)
    if not payload.get("ok"):
        warn(f"could not open a DM with {owner} ({payload.get('error')}); notify left empty")
        return ""
    return payload["channel"]["id"]


# ── workspace ──────────────────────────────────────────────────────────────────


def ensure_workspace(name: str, channels: list[dict]) -> list[str]:
    """Create the channel workspace and give it the house full-access setup. Add-only."""
    ws = os.path.join(home(), "workspaces", name)
    if not os.path.isdir(ws):
        enso("workspace", "create", name)
        info(f"workspace {name}: created")
    notes: list[str] = []

    # AGENTS.md: replace only enso's untouched scaffold.
    agents = os.path.join(ws, "AGENTS.md")
    template = env("WORKSPACE_TEMPLATE")
    with open(agents, encoding="utf-8") as fh:
        current = fh.read()
    if SCAFFOLD_MARK in current and template and os.path.isfile(template):
        with open(template, encoding="utf-8") as fh:
            text = fh.read()
        listing = "\n".join(f"- `#{ch['name']}` (`{ch['id']}`)" for ch in channels) or "- (none resolved yet)"
        owners = split_list(env("SLACK_OWNER_IDS"))
        project = env("PROJECT_DIR")
        text = (
            text.replace("__AGENT_NAME__", env("AGENT_NAME", "the agent"))
            .replace("__CHANNEL_LIST__", listing)
            .replace("__OPERATOR__", f"{env('OPERATOR_NAME') or 'The operator'} (`{owners[0]}`)" if owners else "The operator")
            .replace("__PROJECT_LINE__", f"inspect or edit `{project}`, " if project else "")
            .replace("__LORE_CONTEXT__", env("LORE_CONTEXT") or "(none attached)")
        )
        if not env("LORE_CONTEXT"):
            text = re.sub(r"\n## Project memory\n.*?(?=\n## |\Z)", "\n", text, flags=re.S)
        with open(agents, "w", encoding="utf-8") as fh:
            fh.write(text)
        info(f"workspace {name}: wrote AGENTS.md")

    # MCP: lore over the exe.dev lore-mcp integration (http; no SSH key needed).
    mcp_args: list[str] = []
    context = env("LORE_CONTEXT")
    mcp_path = os.path.join(ws, ".claude", "mcp.json")
    if context:
        url = env("LORE_MCP_URL", "https://lore-mcp.int.exe.xyz/mcp").rstrip("/") + "/" + context
        doc = {"mcpServers": {}}
        if os.path.isfile(mcp_path):
            with open(mcp_path, encoding="utf-8") as fh:
                doc = json.load(fh)
        if doc.setdefault("mcpServers", {}).get("lore") != {"type": "http", "url": url}:
            doc["mcpServers"]["lore"] = {"type": "http", "url": url}
            os.makedirs(os.path.dirname(mcp_path), exist_ok=True)
            with open(mcp_path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(doc, indent=2) + "\n")
            info(f"workspace {name}: lore MCP → {url}")
        mcp_args = ["--strict-mcp-config", "--mcp-config", mcp_path]
        notes.append(f"   lore:     context '{context}' → workspace '{name}' via {url}")

    # workspace.json: written once; after that it is the operator's.
    settings = os.path.join(ws, "workspace.json")
    project = env("PROJECT_DIR")
    if os.path.exists(settings):
        info(f"workspace {name}: workspace.json exists; left alone")
    elif project or mcp_args:
        args = (["--add-dir", project] if project else []) + ["--dangerously-skip-permissions"] + mcp_args
        doc = {
            "agent": {"provider": "claude", "model": env("DEFAULT_MODEL", "opus"), "effort": env("DEFAULT_EFFORT", "high")},
            "providers": {"claude": {"args": args}},
        }
        fd = os.open(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(doc, indent=2) + "\n")
        info(f"workspace {name}: wrote workspace.json (full access{', project ' + project if project else ''})")

    # Project definition for the checkout, so enso tasks/worktrees know it.
    if project:
        projects = os.path.join(ws, "projects")
        if not any(os.path.isfile(os.path.join(projects, d, "PROJECT.md")) for d in os.listdir(projects)):
            key = re.sub(r"[^A-Z0-9]", "", name.upper())[:10] or "PROJ"
            if not key[0].isalpha():
                key = "P" + key[:9]
            os.makedirs(os.path.join(projects, key), exist_ok=True)
            with open(os.path.join(projects, key, "PROJECT.md"), "w", encoding="utf-8") as fh:
                fh.write(f"---\nname: {name.replace('-', ' ').title()}\nstages:\n- work\nrepo: {project}\n---\n")
            info(f"workspace {name}: project {key} → {project}")
    return notes


# ── config.json ────────────────────────────────────────────────────────────────


def providers() -> dict:
    listing = enso_json("providers")
    wanted = {
        "claude": ["--dangerously-skip-permissions"],
        "codex": ["--dangerously-bypass-approvals-and-sandbox"],
    }
    out: dict = {}
    for p in listing.get("providers", []):
        if p["id"] in wanted and p.get("installed"):
            out[p["id"]] = {
                "path": shutil.which(p["id"]) or p["id"],
                "models": [m["id"] for m in p.get("models", [])],
                "args": wanted[p["id"]],
            }
    if "claude" not in out:
        die("enso does not see the claude CLI on PATH")
    return out


def main() -> None:
    agent = env("AGENT_NAME", "the bot")
    cfg_path = os.path.join(home(), "config.json")
    existing: dict | None = None
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as fh:
            existing = json.load(fh)
        if existing.get("version") != 2:
            die(f"{cfg_path} is not an enso 0.4 config (no \"version\": 2); migrate it with install.sh --migrate")
    old_slack = ((existing or {}).get("transports") or {}).get("slack") or {}

    bot = env("SLACK_BOT_TOKEN") or old_slack.get("bot_token", "")
    app = env("SLACK_APP_TOKEN") or old_slack.get("app_token", "")
    check_tokens(bot, app)

    owners = split_list(env("SLACK_OWNER_IDS"))
    if not owners:
        die("SLACK_OWNER_IDS must list at least one Slack user ID (U…)")
    for owner in owners:
        if not USER_ID_RE.fullmatch(owner):
            die(f"'{owner}' does not look like a Slack user ID (e.g. U02FB3JNB)")

    wanted = split_list(env("CHANNELS"))
    workspace = env("CHANNEL_WORKSPACE")
    if wanted and not workspace:
        workspace = re.sub(r"[^a-z0-9]+", "-", wanted[0].lstrip("#").lower()).strip("-")
    if workspace and (not WORKSPACE_RE.fullmatch(workspace) or workspace == "default"):
        die(f"CHANNEL_WORKSPACE {workspace!r} must be lowercase kebab-case and not 'default'")

    channels, pending = resolve_channels(bot, wanted, agent) if wanted else ([], [])
    lines: list[str] = []
    if workspace:
        lines += ensure_workspace(workspace, channels)

    dm_ws = env("DM_WORKSPACE") or "default"
    if dm_ws != "default" and not os.path.isdir(os.path.join(home(), "workspaces", dm_ws)):
        die(f"DM_WORKSPACE {dm_ws!r} does not exist in {home()}/workspaces")
    bindings = {f"slack:dm:{o}": dm_ws for o in owners}
    bindings.update({f"slack:{ch['id']}": workspace for ch in channels})

    if existing is None:
        notify = env("NOTIFY_CHANNEL") or owner_dm(bot, owners[0])
        doc = {
            "version": 2,
            "transports": {"slack": {
                "bot_token": bot, "app_token": app, "notify": notify,
                "mention_required": True, "thread_mention_required": False,
            }},
            "bindings": bindings,
            "defaults": {"provider": "claude", "model": env("DEFAULT_MODEL", "opus"), "effort": env("DEFAULT_EFFORT", "high")},
            "providers": providers(),
            "agent": {"timeout": int(env("AGENT_TIMEOUT", "1800"))},
            "logging": {"level": "INFO"},
            "runs": {"keep": 500, "max_age_days": 30},
            "heartbeat": {"enabled": True, "retention_days": 30},
            "web": {"host": "127.0.0.1", "port": int(env("WEB_PORT", "1337")), "hosts": [f"{env('VM_NAME')}.exe.xyz"]},
        }
        enso_json("config", "apply", "--file", "-", "--expected-hash", "missing", stdin=json.dumps(doc))
        info(f"wrote {cfg_path} ({len(bindings)} bindings, notify {notify or 'unset'})")
    else:
        changed = []
        for key, ws in bindings.items():
            have = existing.get("bindings", {}).get(key)
            if have is None:
                enso("config", "set", f"bindings.{key}", ws)
                changed.append(key)
            elif have != ws:
                warn(f"{key} is already bound to workspace {have!r}; left alone")
        for field, value in (("bot_token", env("SLACK_BOT_TOKEN")), ("app_token", env("SLACK_APP_TOKEN"))):
            if value and value != old_slack.get(field):
                enso("config", "set", f"transports.slack.{field}", value)
                changed.append(f"transports.slack.{field}")
        info(f"config.json exists; {'updated ' + ', '.join(changed) if changed else 'nothing to change'}")

    if channels:
        lines.insert(0, f"   channels: {', '.join('#' + ch['name'] for ch in channels)} → workspace '{workspace}' (full access)")
    if pending:
        lines.append("   • channels still needing you:")
        lines += [f"       - {p}" for p in pending]
        for p in pending:
            warn(p)
    report(lines)


if __name__ == "__main__":
    main()
