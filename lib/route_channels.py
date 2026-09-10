#!/usr/bin/env python3
"""Route the conf's Slack channels to one restricted workspace. Idempotent.

Runs on the VM with enso's venv interpreter, after configure_enso.py has left a
completed setup. Every run converges on the same end state and is safe to
repeat: existing policies, workspaces, routes, and policy files are kept.

  1. Resolve CHANNELS (names or C… ids) against Slack; join public channels the
     bot is not yet in (the manifest grants ``channels:join``). Private channels
     need a human ``/invite`` — they are reported, not failed.
  2. Ensure a restricted policy ``<workspace>-restricted`` exists: a sandboxed
     read-only ``claude/settings.json`` under ``~/.enso/policies/`` (from
     templates/claude-restricted-settings.json, written once) registered with
     ``enso policy create``.
  3. Ensure the workspace exists (``enso workspace create --policy …``) and
     seed its AGENTS.md from templates/AGENTS.workspace.md.
  4. Add an exact route ``transports.slack.channels[C…] = {workspace, audit}``
     for every resolved channel that has none.
  5. Attach lore project memory (LORE_CONTEXT, default ``lore-<workspace>`` when
     that repo exists on the lore host): a ``lore mcp`` server in the policy's
     ``claude/mcp.json`` plus ``mcp__lore__*`` allow rules in its settings.json,
     and a lore section in the workspace AGENTS.md. Applies to a pre-existing
     policy too, add-only.

Inputs from the environment (install.sh exports them):
  CHANNELS, CHANNEL_WORKSPACE, AGENT_NAME, SLACK_MODE, SLACK_BOT_TOKEN,
  ENSO_SLACK_API_BASE_URL (gateway mode), ENSO_BIN, CLAUDE_MODE
  (``oauth-token`` | ``login`` | ``llm-gateway``), LLM_GATEWAY_HOST,
  LORE_CONTEXT, LORE_REMOTE, POLICY_TEMPLATE, WORKSPACE_TEMPLATE,
  ROUTE_REPORT (file that collects summary lines).
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
WORKSPACE_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
RESTRICTED_CHAT_COMMANDS = ("help", "status", "clear", "stop", "use", "model", "effort", "compact")
DEFAULT_CONCURRENCY = "2"
LORE_TOOL_RULES = tuple(
    f"mcp__lore__{tool}" for tool in ("lore_recall", "lore_grep", "lore_read", "lore_remember", "lore_sync_now")
)
LORE_SECTION = """
## Project memory (lore)

The approved `lore` MCP server holds this project's memory (context `__LORE_CONTEXT__`):
synced Slack history, GitHub activity, meeting notes, and derived requests,
decisions, and pinned facts. The `lore-mcp` skill explains how to query it well.

- Answer status, roadmap, "what did we decide", and "what did the client ask"
  questions from lore, and cite the permalinks it returns.
- The GitHub work table in `lore_recall` is authoritative for what is open, in
  progress, or done; Slack and meetings are evidence, not decisions.
- To refresh, call the `lore_sync_now` tool. Never try to run `lore sync`
  yourself: this workspace has no shell, credentials, or network for it.
"""


def credential_passthrough() -> str | None:
    """Which env var a restricted launch must inherit so Claude can authenticate."""
    mode = env("CLAUDE_MODE", "login")
    if mode == "llm-gateway":
        return "ANTHROPIC_BASE_URL"
    if mode == "oauth-token":
        return "CLAUDE_CODE_OAUTH_TOKEN"
    return None  # `login`: Claude reads ~/.claude/.credentials.json; HOME is kept


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"    [routes] {msg}")


def warn(msg: str) -> None:
    print(f"\033[33m    [routes] ! {msg}\033[0m", file=sys.stderr)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def split_list(raw: str) -> list[str]:
    return [p for p in re.split(r"[\s,]+", raw) if p]


def report(lines: list[str]) -> None:
    path = env("ROUTE_REPORT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")


# ── Slack ──────────────────────────────────────────────────────────────────────


class Slack:
    def __init__(self, mode: str, bot_token: str, gateway: str):
        self.mode = mode
        self.bot_token = bot_token
        self.gateway = gateway.rstrip("/")

    def call(self, method: str, **params: str) -> dict:
        if self.mode == "gateway":
            url = f"{self.gateway}/{method}"
            headers = {"Content-Type": "application/x-www-form-urlencoded"}
        else:
            url = f"https://slack.com/api/{method}"
            headers = {
                "Authorization": f"Bearer {self.bot_token}",
                "Content-Type": "application/x-www-form-urlencoded",
            }
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            die(f"Slack {method} failed ({url}): {exc}")
        return {}  # unreachable; keeps type checkers calm

    def list_channels(self) -> dict[str, dict]:
        """Every channel the bot can see: all public ones, private ones it is in."""
        found: dict[str, dict] = {}
        cursor = ""
        while True:
            params = {
                "types": "public_channel,private_channel",
                "exclude_archived": "true",
                "limit": "1000",
            }
            if cursor:
                params["cursor"] = cursor
            payload = self.call("conversations.list", **params)
            if not payload.get("ok"):
                die(f"conversations.list: {payload.get('error', 'unknown error')}")
            for ch in payload.get("channels", []):
                found[ch["id"]] = ch
            cursor = (payload.get("response_metadata") or {}).get("next_cursor", "")
            if not cursor:
                break
        return found


def resolve_channels(slack: Slack, wanted: list[str], agent: str) -> tuple[list[dict], list[str]]:
    """Return (resolved channel dicts with id/name/is_private/is_member, pending notes)."""
    visible = slack.list_channels()
    by_name = {ch.get("name", "").lower(): ch for ch in visible.values()}
    resolved: list[dict] = []
    pending: list[str] = []
    for raw in wanted:
        token = raw.lstrip("#")
        ch: dict | None
        if CHANNEL_ID_RE.fullmatch(token):
            ch = visible.get(token)
            if ch is None:
                payload = slack.call("conversations.info", channel=token)
                if payload.get("ok"):
                    ch = payload["channel"]
                else:
                    # A private channel the bot is not in looks exactly like this.
                    pending.append(
                        f"{token}: not visible to the bot ({payload.get('error')}). "
                        f"If it is private, /invite @{agent} there; the route is in place."
                    )
                    resolved.append({"id": token, "name": token, "is_private": True, "is_member": False, "unverified": True})
                    continue
        else:
            ch = by_name.get(token.lower())
            if ch is None:
                pending.append(
                    f"#{token}: no channel by that name is visible to the bot. Check the spelling; "
                    f"if it is private, /invite @{agent} to it and re-run install.sh."
                )
                continue
        resolved.append(
            {
                "id": ch["id"],
                "name": ch.get("name", ch["id"]),
                "is_private": bool(ch.get("is_private")),
                "is_member": bool(ch.get("is_member")),
            }
        )
    return resolved, pending


def ensure_membership(slack: Slack, channels: list[dict], agent: str) -> list[str]:
    pending: list[str] = []
    for ch in channels:
        if ch.get("is_member") or ch.get("unverified"):
            continue
        if ch["is_private"]:
            pending.append(f"#{ch['name']} ({ch['id']}) is private: /invite @{agent} there. The route is in place.")
            continue
        payload = slack.call("conversations.join", channel=ch["id"])
        if payload.get("ok"):
            ch["is_member"] = True
            info(f"joined #{ch['name']} ({ch['id']})")
        else:
            pending.append(
                f"#{ch['name']} ({ch['id']}): could not join ({payload.get('error')}); "
                f"/invite @{agent} there. The route is in place."
            )
    return pending


# ── enso ───────────────────────────────────────────────────────────────────────


def enso(*args: str) -> None:
    cmd = [env("ENSO_BIN") or "enso", *args]
    proc = subprocess.run(cmd, text=True, capture_output=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        if line.strip():
            print(f"        {line}")
    if proc.returncode != 0:
        die(f"`{' '.join(cmd[1:])}` exited {proc.returncode}")


def _write_private(path: str, content: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)


def ensure_policy_dir(policy_dir: str) -> bool:
    """Create <policy_dir>/claude/settings.json from the template once. Returns True if written."""
    settings = os.path.join(policy_dir, "claude", "settings.json")
    if os.path.exists(settings):
        return False
    with open(env("POLICY_TEMPLATE"), encoding="utf-8") as fh:
        doc = json.load(fh)
    if env("CLAUDE_MODE") == "llm-gateway":
        domains = doc["sandbox"]["network"]["allowedDomains"]
        host = env("LLM_GATEWAY_HOST", "llm.int.exe.xyz")
        if host not in domains:
            domains.append(host)
    os.makedirs(os.path.join(policy_dir, "claude"), mode=0o700, exist_ok=True)
    os.chmod(policy_dir, 0o700)
    os.chmod(os.path.join(policy_dir, "claude"), 0o700)
    _write_private(settings, json.dumps(doc, indent=2) + "\n")
    return True


def ensure_policy(config: dict, name: str, policy_dir: str) -> None:
    if name in config.get("policies", {}):
        info(f"policy {name}: already registered")
        return
    args = [
        "policy", "create", name,
        "--policy-dir", policy_dir,
        "--provider", "claude",
        "--default-provider", "claude",
    ]
    for cmd in RESTRICTED_CHAT_COMMANDS:
        args += ["--chat-command", cmd]
    # Restricted launches receive only the provider's own env key (ANTHROPIC_API_KEY);
    # the credential the operator actually configured must be admitted explicitly.
    needed = credential_passthrough()
    if needed:
        args += ["--env-passthrough", needed]
    enso(*args)
    info(f"policy {name}: registered ({policy_dir})")


def _commit(paths_root: str, target: str, message: str) -> None:
    subprocess.run(["git", "-C", paths_root, "add", os.path.relpath(target, paths_root)], check=False)
    subprocess.run(["git", "-C", paths_root, "commit", "-q", "-m", message], check=False, capture_output=True)


def seed_workspace_agents(paths_root: str, workspace: str, channels: list[dict]) -> None:
    template = env("WORKSPACE_TEMPLATE")
    if not template or not os.path.isfile(template):
        return
    target = os.path.join(paths_root, "workspaces", workspace, "AGENTS.md")
    if os.path.islink(target):
        return
    names = ", ".join(f"`#{ch['name']}`" for ch in channels) or "routed to it"
    with open(template, encoding="utf-8") as fh:
        text = fh.read()
    text = (
        text.replace("__WORKSPACE__", workspace)
        .replace("__CHANNELS__", names)
        .replace("__AGENT_NAME__", env("AGENT_NAME", "the agent"))
    )
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    _commit(paths_root, target, f"bootstrap: seed {workspace} workspace instructions")


# ── lore ───────────────────────────────────────────────────────────────────────


def lore_context_exists(context: str) -> bool | None:
    """True/False if the lore host answered, None if it could not be reached."""
    remote = env("LORE_REMOTE")
    if not remote or ":" not in remote:
        return None
    host, root = remote.split(":", 1)
    proc = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, "test", "-d", f"{root}/{context}.git"],
        capture_output=True, text=True,
    )
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    return None  # 255: ssh itself failed (key not registered yet, host down)


def wire_lore(paths_root: str, policy_dir: str, workspace: str, context: str) -> list[str]:
    """Attach the lore MCP server to the policy and describe it to the workspace. Add-only."""
    notes: list[str] = []
    lore_bin = shutil.which("lore")
    if not lore_bin:
        warn("lore CLI not on PATH; skipping project-memory wiring")
        return notes
    lore_bin = os.path.realpath(lore_bin)
    claude_dir = os.path.join(policy_dir, "claude")
    settings_path = os.path.join(claude_dir, "settings.json")
    mcp_path = os.path.join(claude_dir, "mcp.json")

    # 1. MCP server definition (the file's presence turns MCP on for the policy).
    if os.path.exists(mcp_path):
        with open(mcp_path, encoding="utf-8") as fh:
            mcp = json.load(fh)
        if "lore" in mcp.get("mcpServers", {}):
            info(f"lore: mcp.json already defines the lore server")
        else:
            mcp.setdefault("mcpServers", {})["lore"] = _lore_server(lore_bin, context)
            _rewrite_private(mcp_path, json.dumps(mcp, indent=2) + "\n")
            info(f"lore: added the lore server to {mcp_path}")
    else:
        _write_private(mcp_path, json.dumps({"mcpServers": {"lore": _lore_server(lore_bin, context)}}, indent=2) + "\n")
        info(f"lore: wrote {mcp_path} (context {context})")

    # 2. Allow rules: under --permission-mode dontAsk an unreferenced MCP tool is denied.
    with open(settings_path, encoding="utf-8") as fh:
        settings = json.load(fh)
    allow = settings.setdefault("permissions", {}).setdefault("allow", [])
    missing = [rule for rule in LORE_TOOL_RULES if rule not in allow]
    if missing:
        allow.extend(missing)
        _rewrite_private(settings_path, json.dumps(settings, indent=2) + "\n")
        info(f"lore: allowed {len(missing)} mcp__lore__* tools in {settings_path}")

    # 3. Tell the workspace what it has.
    agents = os.path.join(paths_root, "workspaces", workspace, "AGENTS.md")
    if os.path.isfile(agents) and not os.path.islink(agents):
        with open(agents, encoding="utf-8") as fh:
            text = fh.read()
        if "lore" not in text.lower():
            with open(agents, "a", encoding="utf-8") as fh:
                fh.write(LORE_SECTION.replace("__LORE_CONTEXT__", context))
            _commit(paths_root, agents, f"bootstrap: describe lore project memory in {workspace}")
            info("lore: added a project-memory section to the workspace AGENTS.md")
    notes.append(f"   lore:     context '{context}' attached to workspace '{workspace}' via the policy's claude/mcp.json")
    return notes


def _lore_server(lore_bin: str, context: str) -> dict:
    home = os.path.expanduser("~")
    return {
        "type": "stdio",
        "command": lore_bin,
        "args": ["mcp", "--context", context],
        "env": {
            "HOME": home,
            "LORE_HOME": os.path.join(home, ".lore"),
            "PATH": f"{os.path.dirname(lore_bin)}:/usr/local/bin:/usr/bin:/bin",
        },
    }


def _rewrite_private(path: str, content: str) -> None:
    tmp = f"{path}.tmp"
    _write_private(tmp, content)
    os.replace(tmp, path)


# ── main ───────────────────────────────────────────────────────────────────────


def main() -> None:
    wanted = split_list(env("CHANNELS"))
    if not wanted:
        info("CHANNELS is blank; nothing to route")
        return

    try:
        from enso.config import CONFIG_DIR, config_lock, load_config, save_config, setup_state, SetupState
    except ImportError as exc:
        die(f"could not import enso config internals (enso 2.x expected): {exc}")

    agent = env("AGENT_NAME", "the bot")
    workspace = env("CHANNEL_WORKSPACE") or re.sub(r"[^a-z0-9]+", "-", wanted[0].lstrip("#").lower()).strip("-")
    if not WORKSPACE_RE.fullmatch(workspace):
        die(f"CHANNEL_WORKSPACE {workspace!r} must be lowercase kebab-case (a-z, 0-9, hyphens)")

    mode = env("SLACK_MODE", "gateway")
    slack = Slack(mode, env("SLACK_BOT_TOKEN"), env("ENSO_SLACK_API_BASE_URL"))
    if mode == "gateway" and not slack.gateway.startswith("https://"):
        die("ENSO_SLACK_API_BASE_URL must be set in gateway mode")

    config = load_config()
    if setup_state(config) is not SetupState.COMPLETE:
        die("enso setup is not complete; configure_enso.py must succeed first")

    channels, pending = resolve_channels(slack, wanted, agent)
    pending += ensure_membership(slack, channels, agent)
    for ch in channels:
        state = "member" if ch.get("is_member") else "not a member yet"
        info(f"#{ch['name']} → {ch['id']} ({'private' if ch['is_private'] else 'public'}, {state})")

    # Policy + workspace. Reuse whatever a previous run (or a human) already made.
    workspaces = config.get("workspaces", {})
    if workspace in workspaces:
        policy_name = workspaces[workspace].get("policy", "?")
        info(f"workspace {workspace}: exists (policy {policy_name})")
        policy = config.get("policies", {}).get(policy_name, {})
        if policy.get("unrestricted"):
            warn(f"workspace {workspace} uses the UNRESTRICTED policy {policy_name}; client channels should not")
        else:
            needed = credential_passthrough()
            if needed and needed not in policy.get("env_passthrough", []):
                warn(
                    f"policy {policy_name} does not pass {needed} through to restricted launches; "
                    f"Claude will have no credential in #{workspace} unless it is logged in on this VM. "
                    f"Re-create the policy with `enso policy create … --env-passthrough {needed}`."
                )
    else:
        policy_name = f"{workspace}-restricted"
        policy_dir = os.path.join(CONFIG_DIR, "policies", policy_name)
        if ensure_policy_dir(policy_dir):
            info(f"wrote {policy_dir}/claude/settings.json (read-only sandboxed policy; user-owned from now on)")
        ensure_policy(config, policy_name, policy_dir)
        enso("workspace", "create", workspace, "--policy", policy_name, "--concurrency", DEFAULT_CONCURRENCY)
        info(f"workspace {workspace}: created")
        seed_workspace_agents(CONFIG_DIR, workspace, channels)

    # Exact routes.
    added: list[str] = []
    with config_lock():
        config = load_config()
        routes = config.setdefault("transports", {}).setdefault("slack", {}).setdefault("channels", {})
        for ch in channels:
            existing = routes.get(ch["id"])
            if existing is None:
                routes[ch["id"]] = {"workspace": workspace, "audit": True}
                added.append(ch["id"])
            elif existing.get("workspace") != workspace:
                warn(f"#{ch['name']} ({ch['id']}) is already routed to workspace {existing.get('workspace')!r}; left alone")
        if added:
            save_config(config)
    for ch in channels:
        if ch["id"] in added:
            info(f"routed #{ch['name']} ({ch['id']}) → workspace {workspace}")

    lines = [f"   channels: {', '.join('#' + ch['name'] for ch in channels) or 'none resolved'} → workspace '{workspace}' (policy {policy_name})"]

    # Project memory. Reload: the policy may have been created above.
    config = load_config()
    policy_dir = config.get("policies", {}).get(policy_name, {}).get("policy_dir")
    context = env("LORE_CONTEXT")
    derived = not context
    if derived:
        context = f"lore-{workspace}"
    if not policy_dir:
        info("lore: workspace policy has no policy_dir (unrestricted); not attaching project memory")
    else:
        exists = lore_context_exists(context)
        if exists is False and derived:
            info(f"lore: no context repo '{context}' on the lore host; set LORE_CONTEXT to attach one (or create it with the lore-onboard skill)")
        elif exists is False:
            warn(f"lore: LORE_CONTEXT '{context}' does not exist on the lore host; wiring it anyway so it works once created")
            lines += wire_lore(CONFIG_DIR, os.path.expanduser(policy_dir), workspace, context)
        else:
            if exists is None:
                warn("lore: could not reach the lore host from this VM (key not registered yet?); wiring on trust")
            lines += wire_lore(CONFIG_DIR, os.path.expanduser(policy_dir), workspace, context)
    if pending:
        lines.append("   • channels still needing you:")
        lines += [f"       - {p}" for p in pending]
        for p in pending:
            warn(p)
    report(lines)


if __name__ == "__main__":
    main()
