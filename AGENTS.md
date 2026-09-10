# Provisioning this VM as an enso Slack agent

You are an agent (Shelley or Claude Code) on a fresh exe.dev VM. Your job is to
turn this VM into a configured **enso** Slack agent using this repository, with
as little human effort as possible. Everything mechanical is scripted; only the
secrets and the Slack app creation need a person.

## What you are building

- `enso` (github.com/geekforbrains/enso, v2.x) runs as a systemd `--user`
  service and bridges Slack ↔ the `claude` CLI on this machine.
- The house setup adds: `gh`, `vercel`, `wrangler`, `heroku`, `lore` (project
  memory CLI + its two skills), tokens in `~/.enso/secrets/*.env`, an
  administrative DM route for the operator, and house instructions appended to
  `~/.enso/AGENTS.md`.
- `install.sh` is idempotent. Re-running it is always safe; it never rewrites
  an existing `~/.enso/config.json`.

## Procedure

1. **Check the first-boot install.** If the VM was created by
   `bootstrap.sh new-vm`, tools were pre-installed at boot; confirm with
   `tail ~/enso-agent-bootstrap.log` and `which claude gh vercel wrangler heroku lore`.
   If the log is missing or tools are absent, run `./install.sh --tools-only`
   (takes a few minutes: it builds lore from source).

2. **Ask the human for what only they know.** Gather these before running the
   configure step, in one message, not one at a time:
   - the agent's **name** (Slack display name, e.g. "Ace");
   - their **Slack member ID** (`U…`; Slack profile → ⋯ → Copy member ID) —
     this is the only person the bot will answer over DM;
   - the **Slack channels** the agent should answer in (names or `C…` ids),
     if any. `install.sh` routes them all to one restricted, read-only
     workspace (`CHANNELS` / `CHANNEL_WORKSPACE` in the conf) and joins public
     channels itself. Do not create workspaces, policies, or routes by hand
     for these; put them in the conf;
   - **Slack app + exe.dev integration** (default `SLACK_MODE=gateway`; the
     tokens go straight from the human to exe.dev and never reach you or this
     VM). Print the manifest with `./install.sh --manifest --name "<Name>"` and
     relay these steps for their laptop:
     1. https://api.slack.com/apps?new_app=1 → *From an app manifest* → paste
        → *Install to Workspace* → copy the **Bot User OAuth Token** (`xoxb-…`);
        *Basic Information → App-Level Tokens → Generate* with scope
        `connections:write` → copy the `xapp-…` token.
     2. Store both in exe.dev, named after this VM (`hostname -s`):
        ```
        printf '%s\n%s\n' "xoxb-…" "xapp-…" | ssh exe.dev integrations add slack \
          --name=<vm-name> --bot-token=- --app-token=- --attach vm:<vm-name>
        ```
     Verify from here before continuing:
     `curl -s -X POST https://<vm-name>.int.exe.xyz/api/auth.test` must return
     `"ok":true`. Leave `SLACK_BOT_TOKEN`/`SLACK_APP_TOKEN` blank in the conf.
     Only if the human explicitly wants tokens on the VM, use
     `SLACK_MODE="direct"` and ask for the two tokens instead.
   - a **Claude Code OAuth token** from `claude setup-token` on their laptop,
     or "none", in which case they log in on this VM after install
     (`ssh -t <vm>.exe.xyz claude`, then `/login`). Claude always runs on the
     subscription; never fall back to the exe.dev LLM gateway on your own;
   - the **lore context repo** for the project (e.g. `lore-caremobi`); it is
     attached to the channel workspace at install. If they don't know, leave
     it blank: `lore-<workspace>` is used when it exists on the lore host;
   - optional tool tokens: GitHub PAT, Vercel token, Cloudflare API token +
     account ID, Heroku API key (blank means installed but unauthenticated);
   - optional: notify channel ID, timezone.

3. **Write the conf.** `cp agent.conf.example agent.conf && chmod 600 agent.conf`,
   then fill it in. `VM_NAME` must be this VM's hostname (`hostname -s`); the
   Slack gateway URL is derived from it.

4. **Run it.** `./install.sh agent.conf`. Read the output; it ends with a
   summary and the two remaining human steps.

5. **Verify** before declaring success:
   - `systemctl --user is-active enso.service` prints `active`;
   - `~/apps/enso/.venv/bin/enso config check` passes;
   - if `CHANNELS` was set, the install summary lists each channel as routed to
     the workspace, and a `lore:` line when project memory was attached;
     `enso slack lookup-channel <name>` shows the id it used;
   - ask the human to DM the bot in Slack and confirm it answers, and to
     @mention it in one of the routed channels.
   If the service is not active, `journalctl --user -u enso.service -n 50` has
   the reason; fix it and re-run `./install.sh agent.conf`. `invalid_auth` in
   the log means the exe.dev integration is missing or attached to a different
   VM.

6. **Relay the remaining human steps** verbatim from the install summary:
   registering this VM's SSH key for lore (`ssh exe.dev ssh-key add --tag=lore …`
   must run on their laptop) and, for any **private** channel in `CHANNELS`,
   typing `/invite @<Name>` in it (the route already exists; nothing to re-run).

## Rules

- Never print token values back into chat or logs. Refer to them by name.
- Do not hand-edit `~/.enso/config.json` to work around a failing step; fix the
  input and re-run `install.sh`. The config shape is validated by enso.
- Do not run `enso setup` interactively; `install.sh` does the equivalent.
- Do not commit `agent.conf` (it is gitignored) or copy it into a workspace.
- To route more channels to the same restricted workspace, add them to
  `CHANNELS` in the conf and re-run `./install.sh agent.conf`. A second
  workspace or a different policy is a post-install task with its own
  procedure in the house section of `~/.enso/AGENTS.md`; do it only when asked.
- If `install.sh` stops with "enso at … is version 0.x", upstream enso main
  no longer carries 2.x; ask the human for an `ENSO_REPO`/`ENSO_REF` that does.
