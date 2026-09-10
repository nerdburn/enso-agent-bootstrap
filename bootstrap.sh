#!/usr/bin/env bash
# enso-agent-bootstrap — bootstrap.sh (runs on YOUR LAPTOP)
#
# Drives an exe.dev VM into a configured enso Slack agent over SSH. The heavy
# lifting happens on the VM in install.sh; this script creates the VM, ships the
# conf, and does the few control-plane steps only your exe.dev account can do.
#
#   ./bootstrap.sh manifest          <conf>   print the Slack app manifest JSON
#   ./bootstrap.sh new-vm            <conf>   create the VM (pre-installs tools at first boot)
#   ./bootstrap.sh slack-integration <conf>   SLACK_MODE=gateway: store tokens in exe.dev, attach to VM
#   ./bootstrap.sh deploy [--local]  <conf>   run install.sh on the VM with this conf
#   ./bootstrap.sh lore-key          <conf>   register the VM's SSH key for the lore host
#   ./bootstrap.sh up                <conf>   new-vm (if needed) + slack-integration + deploy + lore-key
#   ./bootstrap.sh status|logs|ssh   <conf>
#
# --local (deploy/up) rsyncs this working copy to the VM instead of pulling
# BOOTSTRAP_REPO — handy while editing the bootstrap itself.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die()  { echo "error: $*" >&2; exit 1; }
log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

CMD="${1:-}"; shift || true
LOCAL=false
if [ "${1:-}" = "--local" ]; then LOCAL=true; shift; fi
CONF="${1:-}"
[ -n "$CMD" ]  || { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -n "$CONF" ] || die "usage: $0 $CMD [--local] <conf>"
[ -f "$CONF" ] || die "config not found: $CONF"
# shellcheck disable=SC1090
source "$CONF"

: "${AGENT_NAME:?set AGENT_NAME in $CONF}"
: "${VM_NAME:?set VM_NAME in $CONF}"
SLACK_MODE="${SLACK_MODE:-gateway}"
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

cmd_slack_integration() {
  [ "$SLACK_MODE" = "gateway" ] || { log "SLACK_MODE=$SLACK_MODE; no exe.dev Slack integration needed"; return 0; }
  if ssh exe.dev integrations list 2>/dev/null | grep -q "^${VM_NAME}  slack "; then
    log "Slack Bot integration '$VM_NAME' already exists (tokens in $CONF may be blanked)"
  else
    : "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN in $CONF (needed once, to create the exe.dev integration)}"
    : "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN in $CONF (needed once, to create the exe.dev integration)}"
    log "creating exe.dev Slack Bot integration '$VM_NAME' (tokens stay off the VM)"
    printf '%s\n%s\n' "$SLACK_BOT_TOKEN" "$SLACK_APP_TOKEN" \
      | ssh exe.dev integrations add slack --name="$VM_NAME" --bot-token=- --app-token=- --attach "vm:$VM_NAME"
  fi
}

cmd_deploy() {
  if [ "$SLACK_MODE" = "direct" ]; then
    : "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN in $CONF}"; : "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN in $CONF}"
  fi
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
  log "running install.sh on $VM_HOST (conf passed over stdin, not argv)"
  ssh "$VM_HOST" "VM_NAME='$VM_NAME' ~/$REMOTE_DIR/install.sh --conf -" < "$CONF"
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

case "$CMD" in
  manifest)          cmd_manifest ;;
  new-vm)            cmd_new_vm ;;
  slack-integration) cmd_slack_integration ;;
  deploy)            cmd_deploy ;;
  lore-key)          cmd_lore_key ;;
  up)                cmd_new_vm; cmd_slack_integration; cmd_deploy; cmd_lore_key
                     echo; echo "✅ '$AGENT_NAME' is live on $VM_HOST — DM it in Slack." ;;
  status)            exec ssh "$VM_HOST" 'systemctl --user status enso.service --no-pager' ;;
  logs)              exec ssh "$VM_HOST" 'journalctl --user -u enso.service -f' ;;
  ssh)               exec ssh "$VM_HOST" ;;
  *)                 die "unknown command: $CMD" ;;
esac
