# enso-agent-bootstrap

Turn a fresh [exe.dev](https://exe.dev) VM into a configured
[enso](https://github.com/geekforbrains/enso) **0.4** Slack agent, set up the way
abby-agent runs: Claude Code behind a Slack bot, a full-access channel
workspace with the project checkout and [lore](https://github.com/nerdburn/lore)
project memory, GitHub through exe.dev integrations, and the house toolkit
(`gh`, `vercel`, `wrangler`, `heroku`, `lore`). One command per agent.

```
laptop                                     exe.dev VM (<name>-agent.exe.xyz)
────────────────────────────────           ─────────────────────────────────────────────
setup.sh        → ace.conf                 install.sh   (idempotent; the whole VM side)
bootstrap.sh    manifest | up | …   ssh →  ├─ CLIs: claude gh(+wrapper) vercel wrangler heroku lore
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
| Slack | Tokens in `~/.enso/config.json` (mode 600). `mention_required: true`, `thread_mention_required: false`. The manifest is enso's own plus `channels:join`, so the bot joins public channels itself. |
| Bindings | `slack:dm:<owner>` → `default` (operator workspace, unrestricted); every `CHANNELS` entry → `CHANNEL_WORKSPACE`. |
| Channel workspace | Full access, like `#merrin`: `workspace.json` gives Claude `--add-dir <checkout> --dangerously-skip-permissions --strict-mcp-config --mcp-config .claude/mcp.json`; `mcp.json` holds only lore over HTTP (`https://lore-mcp.int.exe.xyz/mcp/<context>`). `lore_remember` is allowed but only on an explicit ask (workspace `AGENTS.md`). A `PROJECT.md` points enso's task engine at the checkout. |
| GitHub | exe.dev integrations attached to this VM only (`GITHUB_INTEGRATIONS`; a team integration attaches by giving the VM its client tag). git and gh use `github.int.exe.xyz`; `~/.local/bin/gh` sets `GH_HOST`. The git identity is the exe.dev integration bot. |
| lore | Channel workspace: HTTP via the `lore-mcp` integration (no SSH key). Admin agent: stdio `lore mcp` + the lore CLI, which need the VM's key registered with `ssh exe.dev ssh-key add --tag=lore`. Skills `lore-mcp` and `lore-onboard` are installed in `~/.enso/skills`. |
| Instructions | Home `AGENTS.md` names the agent and adds the house section (identity, operator, lore, thread discipline, tools, software development); `default` gets operator-workspace instructions; `shared/knowledge/People/<operator>.md` records the operator. |
| Credentials | Claude on the subscription (`claude setup-token` in the conf, or `/login` on the VM). Tool tokens go to `~/.config/enso-agent/env`, loaded by `enso.service.d/10-agent-env.conf` (enso 0.4 no longer reads `secrets/*.env`). |

Binding a channel trusts everyone in it with that workspace's capabilities; on
enso 0.4, workspaces organize context and are not security boundaries. If a
client channel should not have the toolchain, give its workspace a restricted
`workspace.json` by hand (accord-agent's sandboxed policy is the worked example).

## Shared defaults (tokens you set once)

Values that are the same for every agent live once in
`~/.config/enso-agent-bootstrap/defaults.conf` (`chmod 600`, conf syntax).
`bootstrap.sh` merges it under each agent's conf; anything an agent conf sets
non-empty wins. Keep Slack tokens out of it.

```bash
VERCEL_TOKEN="…"; CLOUDFLARE_API_TOKEN="…"; CLOUDFLARE_ACCOUNT_ID="…"; HEROKU_API_KEY="…"
LORE_REMOTE="exedev@lore-host.exe.xyz:/srv/lore/repos"
TIMEZONE="America/Vancouver"
OPERATOR_NAME="Shawn Adrian"
```

## Upgrading older agents

- **enso 0.2.0 or later** (official release): `enso update apply` on the VM.
  Check afterwards whether jobs relied on `~/.enso/secrets/*.env` (0.4 stopped
  loading it) and, if so, point `10-agent-env.conf` at the file.
- **Bootstrap-built enso 2.x fork agents**: `./bootstrap.sh migrate ace.conf`
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
| `bootstrap.sh` | laptop | manifest, new-vm, integrations, deploy, migrate, lore-key, up, status, logs |
| `vm-setup-script.sh` | VM, first boot | clone this repo + `install.sh --tools-only` |
| `install.sh` | VM | everything else; idempotent; `--migrate` for enso 2.x-fork homes |
| `lib/configure_enso.py` | VM | Slack checks, channel resolution, channel workspace, `enso config apply`/`set` |
| `lib/read_legacy.py` | VM | reads an old home's tokens/owners/channels/lore context for `--migrate` |
| `lib/slack-manifest.json` | both | enso 0.4's Slack manifest + `channels:join`, name templated |
| `templates/` | VM | house `AGENTS.md` section, channel and operator workspace `AGENTS.md`, operator note |
| `AGENTS.md` / `CLAUDE.md` | VM agent | runbook for an agent doing the setup |
