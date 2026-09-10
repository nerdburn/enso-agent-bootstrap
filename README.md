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

## Shared defaults (tokens you set once)

Values that are the same for every agent — tool tokens, lore remote, timezone,
operator name — live once in `~/.config/enso-agent-bootstrap/defaults.conf`
(`chmod 600`, same syntax as a conf). `bootstrap.sh` merges it under each
agent's conf at deploy time; anything an agent conf sets non-empty wins, and
`setup.sh` marks prompts that already have a default. Keep per-agent secrets
(Slack tokens) out of it. Use agent-scoped tokens, not your personal logins:
your laptop's `gh`, `vercel`, and `wrangler` sessions are OAuth tokens with
refresh chains tied to your account and are not safe or even functional to copy.

```bash
# ~/.config/enso-agent-bootstrap/defaults.conf
GH_TOKEN="github_pat_…"            # fine-grained PAT scoped to the agents' repos
VERCEL_TOKEN="…"                   # vercel.com/account/tokens
CLOUDFLARE_API_TOKEN="…"           # dash.cloudflare.com → My Profile → API Tokens
CLOUDFLARE_ACCOUNT_ID="…"
HEROKU_API_KEY="…"                 # heroku authorizations:create -d agents
LORE_REMOTE="exedev@lore-host.exe.xyz:/srv/lore/repos"
TIMEZONE="America/Vancouver"
OPERATOR_NAME="Shawn Adrian"
```

## Prerequisites

- SSH key registered with exe.dev (`ssh exe.dev` once).
- Permission to create Slack apps in your workspace. Each agent gets **its own
  Slack app** and tokens; never share them between agents.
- Claude runs on the Claude subscription: either a Claude Code OAuth token from
  `claude setup-token` (browser + subscription) in the conf, or leave it blank
  and log in once on the VM after install (`ssh -t <vm>.exe.xyz claude`, then
  `/login`). `CLAUDE_AUTH="exe-gateway"` switches to exe.dev's LLM gateway
  (`llm.int.exe.xyz`, billed to your exe.dev allocation) instead.
- Optional tool tokens: GitHub PAT, Vercel token, Cloudflare API token, Heroku
  API key. The CLIs are installed regardless; tokens make them authenticated.

## What install.sh does on the VM

1. apt deps, Node ≥ 20 check, timezone, git identity.
2. Installs `claude`, `gh`, `heroku`, `vercel`, `wrangler`; clones and builds
   `lore` from source (the npm package omits the skills we need).
3. Clones enso at `ENSO_REF` into `~/apps/enso`, venv, `pip install -e .[slack,web]`.
4. Writes `~/.enso/secrets/claude.env` (the OAuth token, or nothing when you
   log in on the VM; the exe.dev gateway env only with `CLAUDE_AUTH=exe-gateway`)
   and `~/.enso/secrets/tools.env` (tool tokens). `enso serve` loads these,
   so the admin agent inherits them. `gh`/`vercel`/`heroku` are also wired for
   interactive shells.
5. Runs a **non-interactive fresh `enso setup`** via enso's own internals
   (`lib/configure_enso.py`): validates Slack with `auth.test` (through the
   gateway by default), writes
   `config.json` with one admin DM route per `SLACK_OWNER_IDS` entry to the
   `default` workspace (unrestricted `admin` policy), seeds `~/.enso`, records
   the baseline commit. Skipped when a completed setup already exists.
   Then, if `CHANNELS` is set (`lib/route_channels.py`): resolves each channel
   name to its `C…` id, joins public channels the bot is not in, writes a
   sandboxed read-only Claude policy to
   `~/.enso/policies/<workspace>-restricted/claude/settings.json` (once; from
   `templates/claude-restricted-settings.json`), registers it with
   `enso policy create`, creates the workspace with `enso workspace create`,
   seeds its `AGENTS.md`, and adds one exact route per channel under
   `transports.slack.channels`. Existing policy/workspace/routes are reused.
   With `LORE_CONTEXT` (default `lore-<workspace>` if that repo exists on the
   lore host) it also attaches project memory: a `lore mcp` server in the
   policy's `claude/mcp.json`, `mcp__lore__*` allow rules, and a lore section
   in the workspace `AGENTS.md`.
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

- **DM the bot** from a `SLACK_OWNER_IDS` account. Owner DMs go to the
  unrestricted `default` workspace — enso 2.x has no `allowed_users` mode.
- **Channels** come from the conf: `CHANNELS="caremobi caremobi-team"` routes
  both to one restricted workspace (`CHANNEL_WORKSPACE`, default: the first
  channel's name) whose Claude runs sandboxed and read-only. The bot joins
  public channels itself; for a private channel type `/invite @Bot` in it (the
  route is already there). To add channels later, extend `CHANNELS` and re-run
  `install.sh` / `bootstrap.sh deploy`. The policy file is user-owned after the
  first write — tune it on the VM, and test it as enso's
  `docs/specs/permissions.md` describes before trusting it with a client.
- **A second workspace or a trusted internal channel** is a manual step on the
  VM: `enso policy create …`, `enso workspace create <name> --policy <policy>`,
  add `"C…": {"workspace": "<name>", "audit": true}` under
  `transports.slack.channels` in `~/.enso/config.json`, `enso config check`,
  `enso service restart` — or ask the agent, whose house instructions cover it.
- **lore**: `bootstrap.sh lore-key` (part of `up`) registers the VM's key with
  exe.dev scoped to `tag:lore`. `LORE_CONTEXT` in the conf attaches that
  project's memory to the channel workspace at install; if the context repo does
  not exist yet, create it with the `lore-onboard` skill and re-run.
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
| `lib/route_channels.py` | VM | `CHANNELS` → restricted policy + workspace + exact routes; joins public channels |
| `lib/slack-manifest.json` | both | Slack app manifest (mirrors enso's bundled one, name templated) |
| `templates/` | VM | house `AGENTS.md` section, `operator.md`, workspace `AGENTS.md`, restricted Claude `settings.json` |
| `patches/` | VM | Slack API gateway patch for enso, applied when `SLACK_MODE=gateway` (default) |
| `AGENTS.md` / `CLAUDE.md` | VM agent | runbook for an agent doing the setup |
