# enso-agent-bootstrap

Provision an [enso](https://github.com/geekforbrains/enso) Slack agent onto an
exe.dev VM, reproducibly, from your **local machine**. One config file per agent.

The script talks to the VM over SSH (`ssh <vm>.exe.xyz`) and the exe.dev control
plane (`ssh exe.dev …`). Nothing to install locally beyond `ssh`.

## Prerequisites (local)
- SSH key registered with exe.dev (run `ssh exe.dev` once).
- A Claude Code OAuth token: `claude setup-token` on a machine with a browser +
  Claude subscription (the VM is headless).

## Usage

Each agent gets its own `.conf` file (named after the agent, not `ace.conf`).
The repo ships `ace.conf` as an example — replace it with your own agent name.

### Interactive setup (recommended)

The setup TUI walks you through every field and writes a `.conf` file for you:

```bash
./setup.sh
# Prompts for: agent name, VM name, Slack tokens, Claude token, allowed users, etc.
# Writes e.g. jarvis.conf (chmod 600) based on the agent name you choose.
```

### Manual setup

```bash
cp agent.conf.example myagent.conf && chmod 600 myagent.conf
# Edit myagent.conf — set AGENT_NAME, VM_NAME, and any values you have so far.
```

### Deploy workflow

Once you have a `.conf` file (via either method):

```bash
./bootstrap.sh manifest myagent.conf   # print Slack manifest -> paste at api.slack.com
#   Install app, copy Bot token (xoxb-) + App-Level token (xapp-, connections:write)

# Put xoxb-/xapp-/sk-ant-oat01- + ALLOWED_USERS into myagent.conf, then:
# (see "Finding your Slack member ID" below)
./bootstrap.sh deploy myagent.conf     # set CREATE_VM=true to also create the VM

./bootstrap.sh status myagent.conf
./bootstrap.sh logs   myagent.conf
```

## What deploy does on the VM
1. apt deps (python venv, git).
2. Clone enso to `~/apps/enso`, install `.[slack]` in a venv.
3. Rename agent in the bundled manifest.
4. Look up the bot's own user id (auth.test).
5. Write `~/.enso/config.json` + `~/.enso/enso.env` (Claude token, mode 600).
6. Install systemd `--user` service, wire token via `EnvironmentFile=`, enable
   linger (start on boot), restart.

## Finding your Slack member ID
`ALLOWED_USERS` needs Slack member IDs (they look like `U02FB3JNB`). To find yours:
1. In Slack, click on your profile picture (or anyone's name).
2. Click the **three dots** (...) menu.
3. Select **Copy member ID**.

After deploy you can also look up users by name from the VM:
```bash
ssh <vm>.exe.xyz '~/apps/enso/.venv/bin/enso slack lookup-user "name"'
```

## Notes
- `*.conf` files hold live secrets — gitignored; keep `chmod 600`.
- Each agent needs its OWN Slack app (own xoxb-/xapp-). Don't share tokens.
- Find user IDs: `ssh <vm>.exe.xyz '~/apps/enso/.venv/bin/enso slack lookup-user "name"'`
- The agent runs Claude with `--dangerously-skip-permissions`; anyone in
  `ALLOWED_USERS` can make it run shell commands as the VM user. The allowlist
  is your security boundary.
