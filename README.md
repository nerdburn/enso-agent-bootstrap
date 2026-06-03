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
```bash
cp agent.conf.example ace.conf && chmod 600 ace.conf   # edit AGENT_NAME, VM_NAME

./bootstrap.sh manifest ace.conf   # print Slack manifest -> paste at api.slack.com
#   Install app, copy Bot token (xoxb-) + App-Level token (xapp-, connections:write)

# put xoxb-/xapp-/sk-ant-oat01- + ALLOWED_USERS into ace.conf, then:
./bootstrap.sh deploy ace.conf     # set CREATE_VM=true to also create the VM

./bootstrap.sh status ace.conf
./bootstrap.sh logs   ace.conf
```

## What deploy does on the VM
1. apt deps (python venv, git).
2. Clone enso to `~/apps/enso`, install `.[slack]` in a venv.
3. Rename agent in the bundled manifest.
4. Look up the bot's own user id (auth.test).
5. Write `~/.enso/config.json` + `~/.enso/enso.env` (Claude token, mode 600).
6. Install systemd `--user` service, wire token via `EnvironmentFile=`, enable
   linger (start on boot), restart.

## Notes
- `*.conf` files hold live secrets — gitignored; keep `chmod 600`.
- Each agent needs its OWN Slack app (own xoxb-/xapp-). Don't share tokens.
- Find user IDs: `ssh <vm>.exe.xyz '~/apps/enso/.venv/bin/enso slack lookup-user "name"'`
- The agent runs Claude with `--dangerously-skip-permissions`; anyone in
  `ALLOWED_USERS` can make it run shell commands as the VM user. The allowlist
  is your security boundary.
