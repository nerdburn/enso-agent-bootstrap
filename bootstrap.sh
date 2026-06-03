#!/usr/bin/env bash
# enso-agent-bootstrap — provision an exe.dev VM as a Slack enso agent.
# Runs on YOUR LOCAL MACHINE. Talks to the VM over `ssh <vm>.exe.xyz`.
#
# Usage:
#   ./bootstrap.sh manifest <conf>   # print Slack app manifest JSON for the agent
#   ./bootstrap.sh deploy   <conf>   # create VM (if asked) + install/configure agent
#   ./bootstrap.sh status   <conf>   # show the agent service status on the VM
#   ./bootstrap.sh logs     <conf>   # follow the agent logs on the VM
#
# Typical flow:
#   1. cp agent.conf.example ace.conf && chmod 600 ace.conf   # edit names
#   2. ./bootstrap.sh manifest ace.conf                       # paste JSON at api.slack.com
#   3. install the Slack app, copy xoxb-/xapp- tokens into ace.conf
#   4. run `claude setup-token` somewhere with a browser, paste token into ace.conf
#   5. ./bootstrap.sh deploy ace.conf
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

CMD="${1:-}"; CONF="${2:-}"
[ -n "$CMD" ]  || die "usage: $0 {manifest|deploy|status|logs} <conf>"
[ -n "$CONF" ] || die "usage: $0 $CMD <conf>"
[ -f "$CONF" ] || die "config not found: $CONF"

# shellcheck disable=SC1090
source "$CONF"

: "${AGENT_NAME:?set AGENT_NAME in $CONF}"
: "${VM_NAME:?set VM_NAME in $CONF}"
ENSO_REF="${ENSO_REF:-main}"
CREATE_VM="${CREATE_VM:-false}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
VM_HOST="${VM_NAME}.exe.xyz"

# ── Build Slack manifest JSON (name substituted) ────────────────────────────
manifest_json() {
  # Mirrors enso's bundled manifest, with the agent name swapped in.
  cat <<JSON
{
  "display_information": { "name": "${AGENT_NAME}", "description": "Talk to your AI agents from Slack.", "background_color": "#1e1e2e" },
  "features": {
    "bot_user": { "display_name": "${AGENT_NAME}", "always_online": true },
    "app_home": { "home_tab_enabled": false, "messages_tab_enabled": true, "messages_tab_read_only_enabled": false }
  },
  "oauth_config": { "scopes": { "bot": [
    "app_mentions:read","chat:write","chat:write.public","channels:history","channels:join","channels:read",
    "groups:history","groups:read","im:history","im:read","im:write","mpim:history","mpim:read","mpim:write",
    "files:read","files:write","search:read.public","reactions:read","reactions:write","links:read",
    "users:read","users:read.email","users.profile:read"
  ] } },
  "settings": {
    "event_subscriptions": { "bot_events": [
      "app_mention","message.channels","message.groups","message.im","message.mpim",
      "reaction_added","reaction_removed","user_change","team_join","channel_created","channel_rename",
      "channel_archive","channel_unarchive","channel_deleted","member_joined_channel","member_left_channel"
    ] },
    "interactivity": { "is_enabled": false },
    "org_deploy_enabled": false,
    "socket_mode_enabled": true,
    "token_rotation_enabled": false
  }
}
JSON
}

case "$CMD" in
  manifest)
    manifest_json
    echo >&2
    echo "↑ Paste the above at https://api.slack.com/apps?new_app=1 → 'From an app manifest' (JSON tab)." >&2
    exit 0
    ;;

  status)
    need ssh
    exec ssh "$VM_HOST" 'systemctl --user status enso.service --no-pager'
    ;;

  logs)
    need ssh
    exec ssh "$VM_HOST" 'journalctl --user -u enso.service -f'
    ;;

  deploy) : ;; # fall through
  *) die "unknown command: $CMD" ;;
esac

# ── deploy ──────────────────────────────────────────────────────────────────
need ssh
: "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN in $CONF}"
: "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN in $CONF}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in $CONF}"
: "${ALLOWED_USERS:?set ALLOWED_USERS in $CONF}"

# Optionally create the VM via the exe.dev control plane.
if [ "$CREATE_VM" = "true" ]; then
  echo "==> creating VM '$VM_NAME' (cpu=$VM_CPU mem=$VM_MEMORY disk=$VM_DISK)…"
  ssh exe.dev new --name="$VM_NAME" --cpu="${VM_CPU:-2}" \
      --memory="${VM_MEMORY:-4GB}" --disk="${VM_DISK:-20GB}" \
    || die "VM creation failed"
  echo "==> waiting for SSH on $VM_HOST…"
  for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$VM_HOST" true 2>/dev/null; then
      break
    fi
    sleep 5
    [ "$i" = 30 ] && die "VM never became reachable over SSH"
  done
fi

echo "==> provisioning $VM_HOST as agent '$AGENT_NAME'…"

# Secrets and config are passed via env over the SSH channel (not argv),
# so they don't leak into `ps`. The remote payload reads them from its env.
ssh "$VM_HOST" \
  AGENT_NAME="$AGENT_NAME" \
  ENSO_REF="$ENSO_REF" \
  SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  SLACK_APP_TOKEN="$SLACK_APP_TOKEN" \
  CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  ALLOWED_USERS="$ALLOWED_USERS" \
  NOTIFY_CHANNEL="$NOTIFY_CHANNEL" \
  'bash -s' <<'REMOTE'
set -euo pipefail
log() { echo "    [vm] $*"; }

# Normalize allowed users (commas/spaces -> JSON array)
USERS_JSON=$(printf '%s' "$ALLOWED_USERS" | tr ', ' '\n\n' | sed '/^$/d' \
  | awk 'BEGIN{printf "["} {printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')

# 1. System deps
log "installing apt deps…"
sudo apt-get update -qq
sudo apt-get install -y -qq python3-venv python3-pip git >/dev/null

# 2. Clone / update enso
if [ -d "$HOME/apps/enso/.git" ]; then
  log "updating existing enso checkout…"
  git -C "$HOME/apps/enso" fetch -q origin
  git -C "$HOME/apps/enso" checkout -q "$ENSO_REF"
  git -C "$HOME/apps/enso" pull -q --ff-only origin "$ENSO_REF" || true
else
  log "cloning enso ($ENSO_REF)…"
  mkdir -p "$HOME/apps"
  git clone -q --branch "$ENSO_REF" https://github.com/geekforbrains/enso "$HOME/apps/enso" \
    || git clone -q https://github.com/geekforbrains/enso "$HOME/apps/enso"
fi

# 3. venv + install with slack extra
log "creating venv + installing enso[slack]…"
python3 -m venv "$HOME/apps/enso/.venv"
"$HOME/apps/enso/.venv/bin/pip" install -q --upgrade pip
"$HOME/apps/enso/.venv/bin/pip" install -q -e "$HOME/apps/enso[slack]"

# 4. Rename agent in the bundled manifest (for reference/future re-paste)
sed -i -E "s/^(  name: ).*/\1${AGENT_NAME}/; s/^(    display_name: ).*/\1${AGENT_NAME}/" \
  "$HOME/apps/enso/src/enso/slack_manifest.yaml" || true

# 5. Discover the bot's own user id (so it ignores its own messages)
BOT_USER_ID=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  https://slack.com/api/auth.test \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('user_id',''))" 2>/dev/null || true)

# 6. Write config + secrets
mkdir -p "$HOME/.enso/workspace"
ENSO="$HOME/apps/enso/.venv/bin/python"
USERS_JSON="$USERS_JSON" BOT_USER_ID="$BOT_USER_ID" NOTIFY_CHANNEL="$NOTIFY_CHANNEL" \
SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_APP_TOKEN="$SLACK_APP_TOKEN" \
"$ENSO" - <<'PY'
import json, os
from enso import config as cfg
c = cfg.load_config()
c["transport"] = "slack"
c.setdefault("transports", {})["slack"] = {
    "bot_token": os.environ["SLACK_BOT_TOKEN"],
    "app_token": os.environ["SLACK_APP_TOKEN"],
    "bot_user_id": os.environ.get("BOT_USER_ID", ""),
    "allowed_users": json.loads(os.environ["USERS_JSON"]),
    "notify_channel": os.environ.get("NOTIFY_CHANNEL", ""),
}
cfg.save_config(c)
print("    [vm] wrote", cfg.CONFIG_FILE)
PY

umask 077
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "$HOME/.enso/enso.env"
chmod 600 "$HOME/.enso/enso.env"

# 7. Install the systemd --user service, inject the token via EnvironmentFile,
#    enable linger so it runs at boot without an interactive login.
log "installing systemd service…"
"$HOME/apps/enso/.venv/bin/enso" service install >/dev/null 2>&1 || true
UNIT="$HOME/.config/systemd/user/enso.service"
if ! grep -q 'EnvironmentFile=' "$UNIT"; then
  sed -i '/^Environment=PYTHONUNBUFFERED=1/a EnvironmentFile=%h/.enso/enso.env' "$UNIT"
fi
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user restart enso.service

sleep 5
log "service state: $(systemctl --user is-active enso.service)"
log "recent logs:"
journalctl --user -u enso.service --no-pager -n 6 | sed 's/^/        /'
REMOTE

echo
echo "✅ '$AGENT_NAME' deployed on $VM_HOST."
echo "   status: ./bootstrap.sh status $CONF"
echo "   logs:   ./bootstrap.sh logs   $CONF"
echo "   Try DMing $AGENT_NAME in Slack."
