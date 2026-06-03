#!/usr/bin/env bash
# Interactive setup TUI for enso-agent-bootstrap.
# Walks you through creating a .conf file for a new agent.
set -euo pipefail

bold=$'\033[1m' dim=$'\033[2m' reset=$'\033[0m' cyan=$'\033[36m'

prompt() {
  local var="$1" label="$2" default="${3:-}" hint="${4:-}"
  local input
  if [ -n "$hint" ]; then
    echo "${dim}${hint}${reset}" >&2
  fi
  if [ -n "$default" ]; then
    printf "${bold}${label}${reset} [${dim}%s${reset}]: " "$default" >&2
  else
    printf "${bold}${label}${reset}: " >&2
  fi
  read -r input
  eval "$var=\"\${input:-\$default}\""
}

prompt_secret() {
  local var="$1" label="$2" hint="${3:-}"
  local input
  if [ -n "$hint" ]; then
    echo "${dim}${hint}${reset}" >&2
  fi
  printf "${bold}${label}${reset}: " >&2
  read -r input
  eval "$var=\"\$input\""
}

echo ""
echo "${bold}${cyan}enso-agent-bootstrap setup${reset}"
echo "${dim}Creates a .conf file for a new Slack agent.${reset}"
echo ""

# ── Agent identity ───────────────────────────────────────────────────────────
prompt AGENT_NAME "Agent name" "" "Display name for the Slack bot (e.g. Ace, Jarvis, Scout)"

CONF_FILE="$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-').conf"
prompt CONF_FILE "Config filename" "$CONF_FILE"

if [ -f "$CONF_FILE" ]; then
  printf "${bold}%s already exists. Overwrite? [y/N]:${reset} " "$CONF_FILE" >&2
  read -r yn
  case "$yn" in [yY]*) ;; *) echo "Aborted." >&2; exit 1 ;; esac
fi

# ── VM ───────────────────────────────────────────────────────────────────────
echo ""
VM_DEFAULT="$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')-agent"
prompt VM_NAME "exe.dev VM name" "$VM_DEFAULT" "The VM hostname (will be accessible as <name>.exe.xyz)"

prompt CREATE_VM "Create a new VM?" "false" "Set to 'true' to have bootstrap.sh create it"
if [ "$CREATE_VM" = "true" ]; then
  prompt VM_CPU    "VM CPUs"   "2"
  prompt VM_MEMORY "VM memory" "4GB"
  prompt VM_DISK   "VM disk"   "20GB"
else
  VM_CPU=2; VM_MEMORY="4GB"; VM_DISK="20GB"
fi

# ── Slack tokens ─────────────────────────────────────────────────────────────
echo ""
echo "${dim}You can fill these in later after running: ./bootstrap.sh manifest ${CONF_FILE}${reset}"
prompt_secret SLACK_BOT_TOKEN  "Slack Bot Token (xoxb-...)" "Bot User OAuth Token from OAuth & Permissions"
prompt_secret SLACK_APP_TOKEN  "Slack App Token (xapp-...)" "App-Level Token from Basic Info (scope: connections:write)"

# ── Claude token ─────────────────────────────────────────────────────────────
echo ""
prompt_secret CLAUDE_CODE_OAUTH_TOKEN "Claude Code OAuth token (sk-ant-oat01-...)" "Run 'claude setup-token' on a machine with a browser to get this"

# ── Users & channel ──────────────────────────────────────────────────────────
echo ""
prompt ALLOWED_USERS  "Allowed Slack user IDs" "" "Space or comma separated (e.g. U02FB3JNB U12345678)"
prompt NOTIFY_CHANNEL "Default notify channel" "" "Optional channel ID (C...) for unsolicited messages. Leave blank to skip"

ENSO_REF="main"

# ── Write the file ───────────────────────────────────────────────────────────
cat > "$CONF_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────
# enso-agent-bootstrap config for ${AGENT_NAME}.
# Contains SECRETS — keep out of git (see .gitignore) and chmod 600.
# ─────────────────────────────────────────────────────────────────────────

AGENT_NAME="${AGENT_NAME}"

VM_NAME="${VM_NAME}"
CREATE_VM=${CREATE_VM}
VM_CPU=${VM_CPU}
VM_MEMORY=${VM_MEMORY}
VM_DISK=${VM_DISK}

SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-xoxb-...}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-xapp-...}"

CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-sk-ant-oat01-...}"

ALLOWED_USERS="${ALLOWED_USERS}"

NOTIFY_CHANNEL="${NOTIFY_CHANNEL}"

ENSO_REF="${ENSO_REF}"
EOF

chmod 600 "$CONF_FILE"

echo ""
echo "${bold}${cyan}Wrote ${CONF_FILE}${reset} (mode 600)"
echo ""
if [ "${SLACK_BOT_TOKEN:-}" = "" ] || [ "${SLACK_BOT_TOKEN:-}" = "xoxb-..." ]; then
  echo "Next steps:"
  echo "  1. ${bold}./bootstrap.sh manifest ${CONF_FILE}${reset}  — copy the JSON into api.slack.com"
  echo "  2. Install the app, then paste xoxb-/xapp- tokens into ${CONF_FILE}"
  echo "  3. ${bold}./bootstrap.sh deploy ${CONF_FILE}${reset}"
else
  echo "Next steps:"
  echo "  1. ${bold}./bootstrap.sh manifest ${CONF_FILE}${reset}  — if you haven't created the Slack app yet"
  echo "  2. ${bold}./bootstrap.sh deploy ${CONF_FILE}${reset}"
fi
