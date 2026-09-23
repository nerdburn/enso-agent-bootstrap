# Provisioning this VM as an enso Slack agent

You are an agent (Shelley or Claude Code) on an exe.dev VM. Your job is to turn
this VM into a configured **enso** Slack agent using this repository, with as
little human effort as possible. Everything mechanical is scripted; only the
secrets, the Slack app, and the exe.dev control-plane steps need a person.

## What you are building

- `enso` **0.4** (the official release from github.com/geekforbrains/enso),
  installed as a managed runtime under `~/.enso/runtime` with the launcher
  `~/.local/bin/enso`, running as the systemd `--user` service `enso.service`.
- The house setup, modelled on abby-agent: owner DMs bound to the `default`
  operator workspace; the project's Slack channels bound to one **full-access**
  channel workspace (Claude with `--dangerously-skip-permissions`, the project
  checkout added, lore as its only MCP server over the exe.dev `lore-mcp`
  integration); GitHub through exe.dev integrations at `github.int.exe.xyz`
  with a `gh` wrapper; `vercel`, `wrangler`, `heroku`, `lore` + its skills;
  house instructions in `~/.enso/AGENTS.md`; an operator knowledge note.
- `install.sh` is idempotent. Re-running is always safe; an existing
  `config.json` is only extended (missing bindings, changed tokens), never replaced.

## Procedure

1. **Check the first-boot install.** If the VM was created by
   `bootstrap.sh new-vm`, tools were pre-installed at boot; confirm with
   `tail ~/enso-agent-bootstrap.log` and `which claude gh vercel wrangler heroku lore enso`.
   Otherwise run `./install.sh --tools-only` (a few minutes: it builds lore).
   If `~/.enso` already holds an older enso (the 2.x fork or ≤1.x), see
   **Migrating** below instead.

2. **Ask the human for what only they know**, in one message:
   - the agent's **name** (Slack display name);
   - their **Slack member ID** (`U…`; Slack profile → ⋯ → Copy member ID);
   - the **Slack channels** the agent should answer in (names or `C…` ids).
     They are all bound to one full-access workspace (`CHANNELS` /
     `CHANNEL_WORKSPACE`); say plainly that everyone in those channels can use
     the whole toolchain on this VM. Do not create workspaces or bindings by hand;
   - the **Slack app tokens**. Print the manifest with
     `./install.sh --manifest --name "<Name>"` and relay: create the app at
     https://api.slack.com/apps?new_app=1 → *From an app manifest* → paste →
     *Install to Workspace* → copy the **Bot User OAuth Token** (`xoxb-…`);
     *Basic Information → App-Level Tokens → Generate* with scope
     `connections:write` → copy the `xapp-…` token. enso 0.4 stores both in
     `~/.enso/config.json` (mode 600); there is no exe.dev gateway mode any more;
   - the **lore context** (e.g. `lore-merrin`) and, if there is code, the
     **exe.dev GitHub integration** name(s) and the **repo** (`owner/repo`);
   - a **Claude Code OAuth token** from `claude setup-token`, or "none", in
     which case they log in on this VM after install (`ssh -t <vm>.exe.xyz claude`,
     then `/login`). Claude always runs on the subscription; never fall back to
     the exe.dev LLM gateway on your own;
   - optional: Vercel / Cloudflare / Heroku tokens, notify channel, timezone.

3. **Relay the exe.dev steps** (only the human's laptop can do them):
   `./bootstrap.sh integrations <conf>` from the repo on their laptop, or:
   ```
   ssh exe.dev integrations attach lore-mcp vm:<vm-name>
   ssh exe.dev integrations attach <github-integration> vm:<vm-name>   # team integration: ssh exe.dev tag <vm-name> <its client tag>
   ```
   Never tag an agent VM `lore`: that tag carries every client's integrations.
   Verify from here: `curl -s -o /dev/null -w '%{http_code}' https://lore-mcp.int.exe.xyz/mcp/<context>`
   prints 400 (403 means not attached), and
   `git ls-remote https://github.int.exe.xyz/<owner>/<repo>.git` lists refs.

4. **Write the conf.** `cp agent.conf.example agent.conf && chmod 600 agent.conf`,
   then fill it in. `VM_NAME` must be `hostname -s`.

5. **Run it.** `./install.sh agent.conf`. Read the output; it ends with a
   summary and the remaining human steps.

6. **Verify** before declaring success:
   - `systemctl --user is-active enso.service` prints `active`, and `enso logs`
     shows `slack connected as @<bot>`;
   - `enso doctor --attention` has no errors;
   - the summary lists each channel bound to the workspace and a `lore:` line;
   - in the channel workspace, a quick `claude -p` with its `workspace.json`
     arguments can call `lore_recall`;
   - ask the human to DM the bot and @mention it in a bound channel.
   If the service is not active, `~/.enso/launchd.log` and `enso logs` have the
   reason; fix the input and re-run `./install.sh agent.conf`.

7. **Relay the remaining human steps** from the summary: the lore SSH key
   (`ssh exe.dev ssh-key add --tag=lore …`, for the admin agent's lore CLI) and
   `/invite @<Name>` in any **private** channel.

## Migrating an older enso home

enso 0.4 upgrades homes from 0.2.0 onward in place (`enso update apply`); it
cannot read the enso 2.x fork (the old `nerdburn/enso` v2 mirror) or ≤1.x
layouts. `./install.sh --migrate agent.conf` handles the bootstrap-built 2.x
agents: it reads tokens, owners, channels and the lore context from the old
config (the conf wins where set), checks the Slack tokens, **then** stops the
old service, tars the home to `~/backups/`, moves it to `~/.enso-legacy-<ts>`,
installs fresh, carries the channel workspace's `knowledge/` over, and prints
rollback commands if anything fails. A stopped run resumes from
`~/.enso-legacy-path`. VMs whose gateway-mode config holds placeholder tokens
need the real `xoxb-`/`xapp-` tokens in the conf first; it refuses before
touching anything otherwise. A home with several channel workspaces or custom
policies (accord-agent, for example) is migrated by hand, keeping its
workspace directory at the same path.

## Rules

- Never print token values into chat or logs. Refer to them by name.
- Change configuration through `enso config apply` / `enso config set` (what
  `install.sh` does), not by editing `config.json` in place.
- Do not run `enso setup` interactively; `install.sh` does the equivalent.
- Do not commit `agent.conf` (it is gitignored) or copy it into a workspace.
- More channels for the same workspace: add them to `CHANNELS` and re-run.
  A second workspace, a restricted policy, or jobs are post-install work; use
  the bundled `enso-workspace`, `enso-config` and `enso-jobs` skills.
- Upgrades after install go through enso itself: `enso update check`, then
  `enso update apply` (snapshotted, rolls back on failure). The nightly
  `default:enso-update` job announces new releases.
- enso 0.4 no longer loads `~/.enso/secrets/*.env`. Tool tokens live in
  `~/.config/enso-agent/env`, loaded by the drop-in
  `~/.config/systemd/user/enso.service.d/10-agent-env.conf`.
