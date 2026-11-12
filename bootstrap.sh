#!/usr/bin/env bash
# enso-agent-bootstrap — bootstrap.sh (runs on YOUR LAPTOP)
#
# Drives an exe.dev VM into a configured enso 0.4 Slack agent over SSH. The
# heavy lifting happens on the VM in install.sh; this script creates the VM,
# ships the conf, and does the few control-plane steps only your exe.dev
# account can do (integrations, SSH keys).
#
#   ./bootstrap.sh manifest          <conf>   print the Slack app manifest JSON
#   ./bootstrap.sh new-vm            <conf>   create the VM (pre-installs tools at first boot)
#   ./bootstrap.sh integrations      <conf>   attach lore-mcp + GITHUB_INTEGRATIONS to the VM
#   ./bootstrap.sh deploy [--local]  <conf>   run install.sh on the VM with this conf
#   ./bootstrap.sh migrate [--local] <conf>   integrations + install.sh --migrate (enso 2.x fork → 0.4)
#   ./bootstrap.sh lore-key          <conf>   register the VM's SSH key for the lore host
#   ./bootstrap.sh mail-key          <conf>   mint this agent's agent-mail key (AGENT_EMAIL) into the conf
#   ./bootstrap.sh web-login         <conf>   sign the VM's claude.ai browser in (you solve the CAPTCHA)
#   ./bootstrap.sh up                <conf>   new-vm (if needed) + integrations + deploy + lore-key
#   ./bootstrap.sh status|logs|ssh   <conf>
#
# --local (deploy/migrate/up) rsyncs this working copy to the VM instead of
# pulling BOOTSTRAP_REPO — handy while editing the bootstrap itself.
#
# Values every agent shares (tool tokens, lore remote, timezone, operator) go
# once in ~/.config/enso-agent-bootstrap/defaults.conf (chmod 600); an agent's
# conf only needs what differs. Non-empty agent values win.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die()  { echo "error: $*" >&2; exit 1; }
log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

CMD="${1:-}"; shift || true
LOCAL=false
if [ "${1:-}" = "--local" ]; then LOCAL=true; shift; fi
CONF="${1:-}"
[ -n "$CMD" ]  || { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -n "$CONF" ] || die "usage: $0 $CMD [--local] <conf>"
[ -f "$CONF" ] || die "config not found: $CONF"

# Shared defaults (tool tokens, lore remote, timezone, …) live once in
# ~/.config/enso-agent-bootstrap/defaults.conf; the agent conf overrides any
# value it sets non-empty. The merged result is what reaches the VM.
DEFAULTS="${ENSO_AGENT_DEFAULTS:-$HOME/.config/enso-agent-bootstrap/defaults.conf}"
MERGED="$(mktemp)"; chmod 600 "$MERGED"; trap 'rm -f "$MERGED"' EXIT
[ -f "$DEFAULTS" ] && cat "$DEFAULTS" >> "$MERGED"
grep -Ev '^[A-Za-z_][A-Za-z0-9_]*=(""|'"''"')?$' "$CONF" >> "$MERGED"   # drop empty assignments
# shellcheck disable=SC1090
source "$MERGED"

: "${AGENT_NAME:?set AGENT_NAME in $CONF}"
: "${VM_NAME:?set VM_NAME in $CONF}"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-https://github.com/nerdburn/enso-agent-bootstrap}"
VM_HOST="${VM_NAME}.exe.xyz"
REMOTE_DIR="enso-agent-bootstrap"
need ssh

vm_exists() { ssh -o BatchMode=yes exe.dev ls 2>/dev/null | grep -q "^  • ${VM_NAME}\.exe\.xyz "; }

wait_for_ssh() {
  log "waiting for SSH on $VM_HOST"
  for i in $(seq 1 40); do
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$VM_HOST" true 2>/dev/null && return 0
    sleep 5
  done
  die "$VM_HOST never became reachable over SSH"
}

cmd_manifest() {
  sed "s/__AGENT_NAME__/${AGENT_NAME}/g" "$HERE/lib/slack-manifest.json"
  echo >&2
  echo "↑ Paste at https://api.slack.com/apps?new_app=1 → 'From an app manifest' (JSON tab)." >&2
  echo "  Install to workspace → copy xoxb- (OAuth & Permissions) and create an xapp- token" >&2
  echo "  (Basic Information → App-Level Tokens, scope connections:write) into $CONF." >&2
  echo "  enso 0.4 keeps both tokens in ~/.enso/config.json on the VM (mode 600)." >&2
}

cmd_new_vm() {
  if vm_exists; then log "VM $VM_NAME already exists"; return 0; fi
  log "creating VM $VM_NAME (cpu=${VM_CPU:-2} mem=${VM_MEMORY:-4GB} disk=${VM_DISK:-20GB})"
  sed "s|__BOOTSTRAP_REPO__|${BOOTSTRAP_REPO}|g" "$HERE/vm-setup-script.sh" \
    | ssh exe.dev new --name="$VM_NAME" --cpu="${VM_CPU:-2}" --memory="${VM_MEMORY:-4GB}" \
        --disk="${VM_DISK:-20GB}" --tag=enso-agent --no-email --setup-script=/dev/stdin \
    || die "VM creation failed"
  wait_for_ssh
}

# lore over HTTP (exe.dev integration 'lore-mcp' → lore-host) and GitHub through
# per-client integrations, attached to this VM only — never via a shared tag.
attach() {  # attach <integration>
  local line
  line="$(ssh exe.dev integrations list 2>/dev/null | grep -E "^$1 " || true)"
  if [ -z "$line" ]; then
    echo "  ! no exe.dev integration named '$1' (ssh exe.dev integrations list); skipped" >&2; return 0
  fi
  if printf '%s' "$line" | grep -qE "(^| )vm:${VM_NAME}( |$)"; then
    log "integration $1 already attached to vm:$VM_NAME"
  elif printf '%s' "$line" | grep -q '(team)'; then
    # Team integrations attach only by tag. Recreate it as a personal one
    # attached vm:<agent> + tag:lore, like every other client repo.
    echo "  ! '$1' is a team integration; recreate it without --team (see README) and re-run" >&2; return 0
  else
    log "attaching integration $1 → vm:$VM_NAME"
    ssh exe.dev integrations attach "$1" "vm:$VM_NAME"
  fi
}

cmd_integrations() {
  if [ -n "${LORE_CONTEXT:-}" ]; then
    attach "${LORE_MCP_INTEGRATION:-lore-mcp}"
    # The hosted MCP endpoint also checks the host's own allow list
    # (~/.lore/agents.json); without it Claude sees a 403 and asks for OAuth.
    LORE_HOST="${LORE_REMOTE:-exedev@lore-host.exe.xyz:/srv/lore/repos}"; LORE_HOST="${LORE_HOST%%:*}"
    log "allowing $VM_NAME to open $LORE_CONTEXT on $LORE_HOST"
    ssh "$LORE_HOST" "lore agents allow '$VM_NAME' '$LORE_CONTEXT'" </dev/null
  fi
  for gh_int in $(echo "${GITHUB_INTEGRATIONS:-}" | tr ',' ' '); do attach "$gh_int"; done
  true
}

cmd_deploy() {  # cmd_deploy [install.sh flags]
  : "${SLACK_OWNER_IDS:?set SLACK_OWNER_IDS in $CONF}"
  vm_exists || die "VM $VM_NAME does not exist; run: $0 new-vm $CONF"
  if [ "$LOCAL" = true ]; then
    need rsync
    log "rsyncing this working copy → $VM_HOST:~/$REMOTE_DIR"
    rsync -az --delete --exclude .git --exclude '*.conf' "$HERE"/ "$VM_HOST:$REMOTE_DIR/"
  else
    log "syncing $BOOTSTRAP_REPO on $VM_HOST"
    ssh "$VM_HOST" "set -e; if [ -d ~/$REMOTE_DIR/.git ]; then git -C ~/$REMOTE_DIR pull -q --ff-only; \
      else git clone -q '$BOOTSTRAP_REPO' ~/$REMOTE_DIR; fi" </dev/null
  fi
  log "running install.sh $* on $VM_HOST (conf passed over stdin, not argv)"
  ssh "$VM_HOST" "VM_NAME='$VM_NAME' ~/$REMOTE_DIR/install.sh $* --conf -" < "$MERGED"
}

cmd_lore_key() {
  vm_exists || die "VM $VM_NAME does not exist"
  KEY="$(ssh "$VM_HOST" 'test -f ~/.ssh/id_ed25519.pub || ssh-keygen -q -t ed25519 -N "" -C "$(hostname -s)-lore-access" -f ~/.ssh/id_ed25519 >/dev/null; cat ~/.ssh/id_ed25519.pub' </dev/null)"
  KEYBODY="$(echo "$KEY" | awk '{print $2}')"
  if ssh exe.dev ssh-key list 2>/dev/null | grep -q "$KEYBODY"; then
    log "VM key already registered with exe.dev"
  else
    log "registering ${VM_NAME}'s key with exe.dev, scoped to tag:lore"
    ssh exe.dev ssh-key add --tag=lore "$KEY"
  fi
}

# agent-mail: register AGENT_EMAIL with the mail broker (mail-broker/) and
# store the returned key as AGENT_MAIL_KEY in the conf; `deploy` ships it.
# AGENT_MAIL_URL goes in defaults.conf; the admin key (from the broker's
# setup()) stays on this laptop. Re-running rotates the agent's key.
cmd_mail_key() {
  need curl; need python3
  : "${AGENT_EMAIL:?set AGENT_EMAIL in $CONF (the agent's Claude address, e.g. athena@inputlogic.ca)}"
  : "${AGENT_MAIL_URL:?set AGENT_MAIL_URL (the broker's web app URL) in $DEFAULTS}"
  local admin_file="${AGENT_MAIL_ADMIN_KEY_FILE:-$HOME/.config/enso-agent-bootstrap/agent-mail-admin-key}"
  if [ ! -e "$admin_file" ]; then
    # First use: make the admin key here and claim the fresh broker with it, so
    # the key never passes through a browser or a log.
    log "claiming the mail broker (admin key → $admin_file)"
    mkdir -p "$(dirname "$admin_file")"
    ( umask 077; python3 -I -c 'import secrets; print(secrets.token_hex(32))' > "$admin_file" )
    local claimed
    claimed="$(ADMIN="$(cat "$admin_file")" python3 -I -c '
import json, os; print(json.dumps({"op": "claim", "claim": os.environ["ADMIN"].strip()}))' \
      | curl -sS -L --max-time 90 -H 'Content-Type: application/json' --data-binary @- "$AGENT_MAIL_URL")" || true
    if ! printf '%s' "$claimed" | grep -q '"claimed":true'; then
      rm -f "$admin_file"
      die "could not claim the broker: $(printf '%s' "$claimed" | head -c 300)"
    fi
  fi
  [ -r "$admin_file" ] || die "no broker admin key at $admin_file (see mail-broker/README.md)"
  log "registering $AGENT_EMAIL with the mail broker"
  local resp
  resp="$(ADMIN="$(cat "$admin_file")" ALIAS="$AGENT_EMAIL" python3 -I -c '
import json, os; print(json.dumps({"admin": os.environ["ADMIN"].strip(), "op": "register", "alias": os.environ["ALIAS"]}))' \
    | curl -sS -L --max-time 90 -H 'Content-Type: application/json' --data-binary @- "$AGENT_MAIL_URL")" \
    || die "could not reach the mail broker"
  # The key goes straight from the response into the conf, never to the terminal.
  RESP="$resp" CONF_PATH="$CONF" python3 -I -c '
import json, os, re, sys
try: r = json.loads(os.environ["RESP"])
except ValueError: sys.exit("error: the broker did not return JSON (is the web app deployed with access Anyone?)")
if "key" not in r: sys.exit("error: broker: " + r.get("error", "no key returned"))
p = os.environ["CONF_PATH"]; s = open(p).read()
line = "AGENT_MAIL_KEY=%s" % r["key"]   # hex only, no quoting needed
if re.search(r"^AGENT_MAIL_KEY=.*$", s, re.M):
    s = re.sub(r"^AGENT_MAIL_KEY=.*$", lambda m: line, s, count=1, flags=re.M)
else:
    s = s.rstrip("\n") + "\n" + line + "\n"
open(p, "w").write(s)
print("    stored AGENT_MAIL_KEY for %s in %s" % (r["alias"], p))'
  echo "    next: $0 deploy $CONF   (or --local while the change is unpushed)"
}

# claude-web: the VM's claude.ai browser session, which accepts artifact invitations
# and reads artifacts from other organizations. claude.ai's sign-in has a CAPTCHA,
# so a person signs in: this tunnels the VM's browser screen to localhost:6080.
cmd_web_login() {
  vm_exists || die "VM $VM_NAME does not exist"
  log "claude.ai sign-in screen on $VM_HOST"
  echo "    open http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
  echo "    sign in as ${AGENT_EMAIL:-the agent's address}; the code arrives in agent@inputlogic.ca"
  echo "    (or: ssh $VM_HOST agent-mail search 'from:mail.anthropic.com newer_than:1h'). Then press Enter here."
  ssh -t -o ExitOnForwardFailure=yes -L 6080:127.0.0.1:6080 "$VM_HOST" '~/.local/bin/claude-web login-screen'
  log "checking the session"
  ssh "$VM_HOST" '~/.local/bin/claude-web status' </dev/null
}

case "$CMD" in
  manifest)          cmd_manifest ;;
  new-vm)            cmd_new_vm ;;
  integrations)      cmd_integrations ;;
  deploy)            cmd_deploy ;;
  migrate)           cmd_integrations; cmd_deploy --migrate ;;
  lore-key)          cmd_lore_key ;;
  mail-key)          cmd_mail_key ;;
  web-login)         cmd_web_login ;;
  up)                cmd_new_vm; cmd_integrations; cmd_deploy; cmd_lore_key
                     echo; echo "✅ '$AGENT_NAME' is live on $VM_HOST — DM it in Slack." ;;
  status)            exec ssh "$VM_HOST" 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user status enso.service --no-pager' ;;
  logs)              exec ssh "$VM_HOST" 'export XDG_RUNTIME_DIR=/run/user/$(id -u); journalctl --user -u enso.service -f' ;;
  ssh)               exec ssh "$VM_HOST" ;;
  *)                 die "unknown command: $CMD" ;;
esac
