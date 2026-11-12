# enso-agent-bootstrap

Turn a fresh [exe.dev](https://exe.dev) VM into a configured
[enso](https://github.com/geekforbrains/enso) **0.4** Slack agent, set up the way
abby-agent runs: Claude Code behind a Slack bot, a full-access channel
workspace with the project checkout and [lore](https://github.com/nerdburn/lore)
project memory, GitHub through exe.dev integrations, and the house toolkit
(`gh`, `vercel`, `wrangler`, `heroku`, `neonctl`, `sanity`, `lore`, Playwright + headless Chromium). One command per agent.

```
laptop                                     exe.dev VM (<name>-agent.exe.xyz)
────────────────────────────────           ─────────────────────────────────────────────
setup.sh        → ace.conf                 install.sh   (idempotent; the whole VM side)
bootstrap.sh    manifest | up | …   ssh →  ├─ CLIs: claude gh(+wrapper) vercel wrangler heroku neonctl sanity lore
  integrations: lore-mcp, GitHub → vm      ├─ enso 0.4 managed release → ~/.local/bin/enso
                                           ├─ ~/.enso: config.json, default + channel workspace
                                           ├─ house AGENTS.md, operator note, lore skills
                                           └─ systemd --user enso.service (+ linger)
```

## Three ways to use it

**A. From your laptop (fully scripted)**

```bash
./setup.sh                          # wizard → ace.conf (chmod 600)
./bootstrap.sh manifest ace.conf    # paste JSON at api.slack.com → copy xoxb-/xapp- into ace.conf
./bootstrap.sh up ace.conf          # create VM, attach integrations, install, start, register lore key
```

**B. Tell the VM's agent to do it** (Shelley, or Claude Code on the VM)

```bash
ssh exe.dev new --name ace-agent --tag enso-agent \
  --setup-script=/dev/stdin < vm-setup-script.sh        # pre-installs tools at first boot
ssh exe.dev shelley prompt ace-agent \
  "Set up this VM as an enso Slack agent named Ace using ~/enso-agent-bootstrap — follow its AGENTS.md"
```

[`AGENTS.md`](AGENTS.md) is the runbook for that agent: what to ask you for,
the exe.dev commands only your laptop can run, how to write the conf, run
`install.sh`, verify, and what stays human.

**C. By hand on the VM**

```bash
git clone https://github.com/nerdburn/enso-agent-bootstrap && cd enso-agent-bootstrap
cp agent.conf.example agent.conf && chmod 600 agent.conf && $EDITOR agent.conf
./install.sh agent.conf
```

## The setup it produces

| Piece | What |
| --- | --- |
| enso | Official managed release (`ENSO_VERSION`, default 0.4.0): runtime in `~/.enso/runtime`, launcher `~/.local/bin/enso`, `enso.service` (user unit, linger). Later upgrades: `enso update apply`, announced nightly by `default:enso-update`. |
| Slack | Tokens in `~/.enso/config.json` (mode 600). `mention_required: true`, `thread_mention_required: true` (enforced on every run: the agent answers in a thread only when @mentioned there). The manifest is enso's own plus `channels:join`, so the bot joins public channels itself. |
| Bindings | `slack:dm:<owner>` → `default` (operator workspace, unrestricted); every `CHANNELS` entry → `CHANNEL_WORKSPACE`. |
| Channel workspace | `WORKSPACE_POLICY=full` (the default, like `#merrin`): `workspace.json` gives Claude `--add-dir <checkout> --dangerously-skip-permissions --strict-mcp-config --mcp-config .claude/mcp.json`; `mcp.json` holds only lore over HTTP (`https://lore-mcp.int.exe.xyz/mcp/<context>`); a `PROJECT.md` points enso's task engine at the checkout. `WORKSPACE_POLICY=restricted` (like `#jointly-team`): `.claude/settings.json` is rendered from `templates/settings.restricted.json.tmpl` — strict permission allowlist (lore MCP tools only), sandbox with network + filesystem denies, credential env vars denied; `workspace.json` runs Claude with `--settings … --permission-mode dontAsk --setting-sources project`, no `--add-dir`, no `--dangerously-skip-permissions`. Per-agent extras via `RESTRICTED_ALLOW_DOMAINS` and `RESTRICTED_DENY_WRITE`. |
| GitHub | The shared agent account **inputagents** on github.com: `GH_TOKEN` is its classic PAT (`repo`, `workflow`, `read:org`); `install.sh` runs `gh auth login` with it, logs any other account out, sets up git's credential helper, and commits use its noreply address under "<Name> (Enso agent)". inputagents needs push access to every `PROJECT_REPOS` entry. Without `GH_TOKEN`, git and gh fall back to the exe.dev integrations attached to the VM (`GITHUB_INTEGRATIONS`, via `github.int.exe.xyz` and a `gh` wrapper). Personal, not `--team`, integrations still serve lore-host's sync (`--attach=tag:lore`). |
| lore | Channel workspace: HTTP via the `lore-mcp` integration (no SSH key). Admin agent: stdio `lore mcp` + the lore CLI, which need the VM's key registered with `ssh exe.dev ssh-key add --tag=lore`. Skills `lore-mcp` and `lore-onboard` are installed in `~/.enso/skills`. |
| Instructions | Home `AGENTS.md` names the agent and adds the house section (identity, operator, lore, thread discipline, tools, software development); `default` gets operator-workspace instructions; `shared/knowledge/People/<operator>.md` records the operator. |
| Email + artifacts | `agent-mail` (the agent's own alias in agent@inputlogic.ca, read-only, through the broker in `mail-broker/`) and `claude-web` (its own signed-in claude.ai browser: accepts artifact invitations, reads cross-org artifacts for `claude-artifact`). See "Email and claude.ai artifacts". |
| Credentials | Claude on the subscription (`claude setup-token` in the conf, or `/login` on the VM). Tool tokens go to `~/.config/enso-agent/env`, loaded by `enso.service.d/10-agent-env.conf` (enso 0.4 no longer reads `secrets/*.env`). |

Binding a channel trusts everyone in it with that workspace's capabilities; on
enso 0.4, workspaces organize context and are not security boundaries. Full-access
workspaces are the default; set `WORKSPACE_POLICY=restricted` on a client-facing
agent to run its channel workspace under the committed sandbox policy instead
(`accord.conf` is the worked example — no more hand-editing on the VM).

## Shared defaults (tokens you set once)

Values that are the same for every agent live once in
`~/.config/enso-agent-bootstrap/defaults.conf` (`chmod 600`, conf syntax).
`bootstrap.sh` merges it under each agent's conf; anything an agent conf sets
non-empty wins. Keep Slack tokens out of it.

```bash
VERCEL_TOKEN="…"; CLOUDFLARE_API_TOKEN="…"; CLOUDFLARE_ACCOUNT_ID="…"; HEROKU_API_KEY="…"; NEON_API_KEY="…"
LORE_REMOTE="exedev@lore-host.exe.xyz:/srv/lore/repos"
TIMEZONE="America/Vancouver"
OPERATOR_NAME="Shawn Adrian"
```

## Figma

`FIGMA_ACCESS_TOKEN` (a personal access token, `figd_…`) goes in the service
environment for the REST API. `FIGMA_MCP=yes` adds Figma's official remote MCP
(`https://mcp.figma.com/mcp`) to a full-policy channel workspace's
`.claude/mcp.json`. It authenticates with OAuth, once per VM, as whichever
Figma user signs in. Run it with the same `mcp.json` so the stored login
matches the server the agent uses:

```bash
ssh -t <vm>.exe.xyz 'cd ~/.enso/workspaces/<workspace> && claude --strict-mcp-config --mcp-config .claude/mcp.json'
# /mcp → figma → Authenticate → open the URL on your laptop and approve.
```

The browser then lands on a `http://localhost:<port>/callback?...` page that
cannot load. If Claude does not offer to take the pasted URL, copy it from the
address bar and finish from a second terminal while Claude is still waiting:
`ssh <vm>.exe.xyz "curl -s '<that URL>'"`. Check with `/mcp`, where figma
should show as connected.

## Email and claude.ai artifacts (agent-mail, claude-web)

Every agent's Claude seat is an alias of **agent@inputlogic.ca** (athena@,
joan@, abbe@, …), so all their mail lands in one inbox. Two tools build on that:

**agent-mail**: each agent reads its own mail only. The **broker**
([`mail-broker/`](mail-broker/README.md)) is an Apps Script web app deployed in
agent@ with read-only Gmail. Each VM's key maps to one alias, and the broker
returns a message only if it is addressed to that alias and comes from an
allowlisted sender domain that Gmail authenticated (DMARC/DKIM). Agents can't
read each other's mail, send, or delete. On the VM: `agent-mail whoami | search
| read | links`. Setup per agent, from the laptop:

```bash
# conf: AGENT_EMAIL="athena@inputlogic.ca"   (AGENT_MAIL_URL is in defaults.conf)
./bootstrap.sh mail-key athena.conf   # registers the alias, writes AGENT_MAIL_KEY into the conf
./bootstrap.sh deploy athena.conf     # install.sh checks `agent-mail whoami`
```

The broker is deployed once (done 2026-11-12; project "agent-mail-broker" in
agent@, the URL is `AGENT_MAIL_URL`). The first `mail-key` claimed it with the
admin key in `~/.config/enso-agent-bootstrap/agent-mail-admin-key`.

**agent-docs**: Google Docs, Sheets, Slides, folders and files shared with
the agent's address, through the same broker and key (`mail-broker/Drive.gs`).
Drive can't tell aliases apart, so a file counts as the agent's only if
Google's share email to its alias names it, or a folder it's in. On the VM:
`agent-docs list [<folder link>]` and `agent-docs read <link>` (Docs →
Markdown, Sheets → CSV per tab, Slides → text, other files → `~/docs/`).
Read-only. A file shared without "Notify people" doesn't show up; re-share it with
notification on, or grant it with the broker's admin op `grant`.

**claude-web**: shared claude.ai artifact links. `claude-artifact <link>` reads
an artifact through Claude Code's Artifact tool, which works for links shared
inside Input Logic. A share from **another organization** (a client's own Claude
org) arrives as an emailed *invitation* ("You've been invited to edit an
artifact"), and Claude Code stays refused even after it's accepted. For those,
`claude-artifact` falls back to `claude-web`, a headed Chromium on a virtual
display with its own profile (`~/.local/share/claude-web/profile`), signed in
to claude.ai as the agent. It finds the invitation with `agent-mail`, clicks
*Accept and open*, and saves what the artifact renders (`index.html`,
`page.txt`, `screenshot.png`) to `~/artifacts/<id>/`. Accepting needs no
CAPTCHA, but **claude.ai's sign-in does (hCaptcha)**, so a person signs each
VM's browser in, once per session:

```bash
./bootstrap.sh web-login athena.conf
# open http://localhost:6080/vnc.html?autoconnect=1&resize=scale (the VM's browser),
# sign in as the agent's address; the code arrives in agent@inputlogic.ca
# (or: ssh athena-agent.exe.xyz '~/.local/bin/agent-mail search "from:mail.anthropic.com newer_than:1h"'),
# type it in the VM's browser yourself, then press Enter in the terminal.
```

The screen (Xvfb + x11vnc + noVNC) listens on the VM's 127.0.0.1 only and is
reached through the SSH tunnel. When the session expires, `claude-artifact`
says the browser is signed out and the agent asks for a re-run. Check any time
with `ssh <vm>.exe.xyz '~/.local/bin/claude-web status'`.

Status (2026-11-12): athena has all three (broker version 4); other agents need `AGENT_EMAIL` +
`mail-key` + `deploy`, then one `web-login`.

## Upgrading older agents

- **enso 0.2.0 or later** (official release): `enso update apply` on the VM.
  Check afterwards whether jobs relied on `~/.enso/secrets/*.env` (0.4 stopped
  loading it) and, if so, point `10-agent-env.conf` at the file.
- **enso 2.x fork agents** (bootstrap-built or customized, like tally-agent): `./bootstrap.sh migrate ace.conf`
  (= integrations + `install.sh --migrate`). It checks the Slack tokens first,
  then stops the old service, backs up and moves the old home to
  `~/.enso-legacy-<ts>`, installs fresh, and prints rollback commands on
  failure. Gateway-mode agents need their real `xoxb-`/`xapp-` tokens in the
  conf; enso 0.4 cannot use the exe.dev Slack gateway.
- **Hand-customized or ≤1.x homes**: migrate by hand; see the Migrating
  section of `AGENTS.md`.

## Files

| Path | Runs on | Purpose |
| --- | --- | --- |
| `setup.sh` | laptop | wizard → `<agent>.conf` |
| `bootstrap.sh` | laptop | manifest, new-vm, integrations, deploy, migrate, lore-key, mail-key, web-login, up, status, logs |
| `vm-setup-script.sh` | VM, first boot | clone this repo + `install.sh --tools-only` |
| `install.sh` | VM | everything else; idempotent; `--migrate` for enso 2.x-fork homes |
| `lib/configure_enso.py` | VM | Slack checks, channel resolution, channel workspace, `enso config apply`/`set` |
| `lib/read_legacy.py` | VM | reads an old home's tokens/owners/DM workspace/channels/lore context for `--migrate` |
| `lib/convert_jobs.py` | VM | converts an old home's `jobs/*/JOB.md` to 0.4 workspace jobs for `--migrate` |
| `lib/slack-manifest.json` | both | enso 0.4's Slack manifest + `channels:join`, name templated |
| `bin/agent-mail`, `bin/agent-docs`, `lib/agent-mail.sh` | VM | the agent's own mail and Drive shares via the broker; installer + AGENTS.md "Email" / "Google Drive" sections |
| `bin/claude-web`, `lib/claude-web.js`, `lib/claude-web.sh` | VM | the agent's claude.ai browser session (status, accept, read, login-screen); installer |
| `bin/claude-artifact`, `lib/claude-artifact.sh` | VM | claude.ai artifact links → files (Claude Code, falling back to claude-web) |
| `mail-broker/` | Google (agent@) | Apps Script broker for mail (`Code.gs`) and Drive (`Drive.gs`) + deploy notes |
| `templates/` | VM | house `AGENTS.md` section, channel and operator workspace `AGENTS.md`, operator note |
| `AGENTS.md` / `CLAUDE.md` | VM agent | runbook for an agent doing the setup |
