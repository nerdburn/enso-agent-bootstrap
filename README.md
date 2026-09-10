# enso-agent-bootstrap

Turn a fresh [exe.dev](https://exe.dev) VM into a fully configured
[enso](https://github.com/geekforbrains/enso) Slack agent — Claude Code behind a
Slack bot, plus the house toolkit (`gh`, `vercel`, `wrangler`, `heroku`,
[`lore`](https://github.com/nerdburn/lore) project memory) — in one command per
agent. Tracks enso **2.x** (managed workspaces, exact Slack routes, policies).

```
laptop                                   exe.dev VM (<name>-agent.exe.xyz)
──────────────────────────────           ─────────────────────────────────────────────
setup.sh        → ace.conf               install.sh   (idempotent; the whole VM side)
bootstrap.sh    manifest | up | …  ssh → ├─ CLIs: claude gh vercel wrangler heroku lore
                                         ├─ ~/apps/enso  (venv, .[slack,web])
                                         ├─ ~/.enso      (fresh setup, DM routes, secrets/)
                                         ├─ house AGENTS.md section, operator.md, lore skills
                                         └─ systemd --user enso.service (+ linger)
```

## Three ways to use it

**A. From your laptop (fully scripted)**

```bash
./setup.sh                          # wizard → ace.conf (chmod 600)
./bootstrap.sh manifest ace.conf    # paste JSON at api.slack.com → copy xoxb-/xapp- into ace.conf
./bootstrap.sh up ace.conf          # create VM, hand tokens to exe.dev, install, start, register lore key
```

Slack tokens default to living in an exe.dev **Slack Bot integration** named
after the VM, injected at the network edge. The VM never holds them, and once
`up` has created the integration you can blank them from the conf.

**B. Tell the VM's agent to do it** (Shelley, or Claude Code on the VM)

```bash
ssh exe.dev new --name ace-agent --tag enso-agent \
  --setup-script=/dev/stdin < vm-setup-script.sh        # pre-installs tools at first boot
ssh exe.dev shelley prompt ace-agent \
  "Set up this VM as an enso Slack agent named Ace using ~/enso-agent-bootstrap — follow its AGENTS.md"
```

The repo's [`AGENTS.md`](AGENTS.md) is a runbook for that agent: what to
pre-check, exactly what to ask you for (your member ID, a Claude token or not),
the one command you run on your laptop to hand the Slack tokens to exe.dev, how
to write the conf, run `install.sh`, verify, and which steps stay human. The
Slack tokens never pass through the agent.

**C. By hand on the VM**

```bash
git clone https://github.com/nerdburn/enso-agent-bootstrap && cd enso-agent-bootstrap
cp agent.conf.example agent.conf && chmod 600 agent.conf && $EDITOR agent.conf
./install.sh agent.conf
```

## Prerequisites

- SSH key registered with exe.dev (`ssh exe.dev` once).
- Permission to create Slack apps in your workspace. Each agent gets **its own
  Slack app** and tokens; never share them between agents.
- Optional: a Claude Code OAuth token from `claude setup-token` (browser +
  Claude subscription). Leave it blank and the agent uses exe.dev's LLM gateway
  (`llm.int.exe.xyz`, billed to your exe.dev allocation) instead.
- Optional tool tokens: GitHub PAT, Vercel token, Cloudflare API token, Heroku
  API key. The CLIs are installed regardless; tokens make them authenticated.

## What install.sh does on the VM

1. apt deps, Node ≥ 20 check, timezone, git identity.
2. Installs `claude`, `gh`, `heroku`, `vercel`, `wrangler`; clones and builds
   `lore` from source (the npm package omits the skills we need).
3. Clones enso at `ENSO_REF` into `~/apps/enso`, venv, `pip install -e .[slack,web]`.
4. Writes `~/.enso/secrets/claude.env` (OAuth token, or the exe.dev LLM gateway
   env) and `~/.enso/secrets/tools.env` (tool tokens). `enso serve` loads these,
   so the admin agent inherits them. `gh`/`vercel`/`heroku` are also wired for
   interactive shells.
5. Runs a **non-interactive fresh `enso setup`** via enso's own internals
   (`lib/configure_enso.py`): validates Slack with `auth.test` (through the
   gateway by default), writes
   `config.json` with one admin DM route per `SLACK_OWNER_IDS` entry to the
   `default` workspace (unrestricted `admin` policy), seeds `~/.enso`, records
   the baseline commit. Skipped when a completed setup already exists.
6. Appends the house section to `~/.enso/AGENTS.md` (identity, tool inventory,
   thread discipline, how to route channels, lore), seeds `docs/operator.md`,
   installs the `lore-mcp` and `lore-onboard` skills, commits.
7. `~/.lore/config.json` → lore host; generates an SSH key for it; optionally
   registers the `lore` MCP server for the admin agent (`LORE_CONTEXT`).
8. `enso service install`, enables linger, adds a drop-in with PATH (and the
   Slack gateway URL in gateway mode), restarts, runs `enso config check`.

Re-running `install.sh` updates enso and the tools and repairs structure; it
never rewrites an existing `~/.enso/config.json`.

## Slack token modes

| `SLACK_MODE` | Where the xoxb-/xapp- tokens live | Notes |
| --- | --- | --- |
| `gateway` (default) | An exe.dev **Slack Bot** integration named after the VM (`<vm>.int.exe.xyz`); injected at the network edge | Tokens never touch the VM; `config.json` holds placeholders. `bootstrap.sh slack-integration` (part of `up`) creates it from the conf, or you pipe the tokens to `ssh exe.dev integrations add slack` yourself. `install.sh` preflights `auth.test` through the gateway and applies the vendored `patches/0001-slack-api-gateway.patch` to enso (10 lines, reads `ENSO_SLACK_API_BASE_URL`; written on the accord-agent VM, not yet upstream). |
| `direct` | `~/.enso/config.json` on the VM | No exe.dev integration needed. The unrestricted admin agent can read the tokens. |

The patch is deliberately kept here rather than sent upstream: it exists only
because exe.dev injects tokens at the network edge, which is a property of how
we host agents, not of enso. If an enso update changes the Slack transport so
the patch stops applying, `install.sh` fails with a clear message; refresh the
patch (two hunks) or fall back to `direct` until you do.

## After install: routing channels, memory, more agents

- **DM the bot** from a `SLACK_OWNER_IDS` account. That is the only route until
  you add channels — enso 2.x has no `allowed_users` mode.
- **Route a channel**: invite the bot, then ask the agent to route it, or on the
  VM: `enso workspace create <name> --policy admin`, add
  `"C…": {"workspace": "<name>", "audit": true}` under `transports.slack.channels`
  in `~/.enso/config.json`, `enso config check`, `enso service restart`. For a
  channel clients can see, create a restricted policy first — see enso's
  `docs/configuration.md` and `docs/specs/permissions.md`, and the accord-agent
  VM for a worked example (`~/.enso/policies/jointly-team`).
- **lore**: `bootstrap.sh lore-key` registers the VM's key with exe.dev scoped to
  `tag:lore`. Attach memory per workspace with the `lore-onboard` skill or a
  `lore mcp --context lore-<client>` server in the policy's `claude/mcp.json`.
- **Another agent** = another conf file and another Slack app. VMs are cheap;
  one agent per VM keeps credentials and workspaces apart.

## Finding Slack IDs

Your member ID: Slack profile → ⋯ → **Copy member ID** (`U02FB3JNB`). After
install, from the VM: `enso slack lookup-user "name"`, `enso slack lookup-channel "name"`.

## Security notes

- `*.conf` files hold live secrets — gitignored; keep them `chmod 600`.
  `bootstrap.sh deploy` passes the conf to the VM over stdin, never argv.
- The `default` workspace runs Claude with `--dangerously-skip-permissions` and
  the full service environment (including tool tokens). Anyone with a DM route
  can make it run shell commands as the VM user; the DM routes are the boundary.
- With the defaults (`SLACK_MODE=gateway`, no Claude token → exe.dev LLM
  gateway) the VM holds no Slack or Anthropic credentials at all; only the
  optional tool tokens you choose to give it.

## Files

| Path | Runs on | Purpose |
| --- | --- | --- |
| `setup.sh` | laptop | wizard → `<agent>.conf` |
| `bootstrap.sh` | laptop | manifest, new-vm, slack-integration, deploy, lore-key, up, status, logs |
| `vm-setup-script.sh` | VM, first boot | clone this repo + `install.sh --tools-only` |
| `install.sh` | VM | everything else; idempotent |
| `lib/configure_enso.py` | VM | non-interactive fresh `enso setup` |
| `lib/slack-manifest.json` | both | Slack app manifest (mirrors enso's bundled one, name templated) |
| `templates/` | VM | house `AGENTS.md` section, `operator.md` |
| `patches/` | VM | Slack API gateway patch for enso, applied when `SLACK_MODE=gateway` (default) |
| `AGENTS.md` / `CLAUDE.md` | VM agent | runbook for an agent doing the setup |
