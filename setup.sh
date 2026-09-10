#!/usr/bin/env bash
# Interactive wizard (runs on your laptop): writes a .conf file for a new agent.
# Every prompt has a sensible default; secrets can be left blank and filled in
# later. Then: ./bootstrap.sh manifest <conf> → paste → ./bootstrap.sh up <conf>
set -euo pipefail

bold=$'\033[1m' dim=$'\033[2m' reset=$'\033[0m' cyan=$'\033[36m'

prompt() {  # prompt VAR "Label" "default" "hint"
  local var="$1" label="$2" default="${3:-}" hint="${4:-}" input
  [ -n "$hint" ] && echo "${dim}${hint}${reset}" >&2
  if [ -n "$default" ]; then printf "${bold}%s${reset} [${dim}%s${reset}]: " "$label" "$default" >&2
  else printf "${bold}%s${reset}: " "$label" >&2; fi
  read -r input
  printf -v "$var" '%s' "${input:-$default}"
}
prompt_secret() {  # prompt_secret VAR "Label" "hint"   (blank allowed)
  local var="$1" label="$2" hint="${3:-}" input
  [ -n "$hint" ] && echo "${dim}${hint}${reset}" >&2
  printf "${bold}%s${reset} ${dim}(blank to skip)${reset}: " "$label" >&2
  read -rs input; echo >&2
  printf -v "$var" '%s' "$input"
}
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'; }

echo; echo "${bold}${cyan}enso-agent-bootstrap setup${reset}"
echo "${dim}Creates a .conf for a new Slack agent on exe.dev.${reset}"; echo

# Shared defaults: anything set in ~/.config/enso-agent-bootstrap/defaults.conf
# is applied by bootstrap.sh at deploy time, so those prompts can stay blank.
DEFAULTS="${ENSO_AGENT_DEFAULTS:-$HOME/.config/enso-agent-bootstrap/defaults.conf}"
D_GH="" D_VERCEL="" D_CF="" D_CFID="" D_HEROKU="" D_CLAUDE="" D_LORE="" D_TZ="" D_OP=""
if [ -f "$DEFAULTS" ]; then
  # shellcheck disable=SC1090
  ( source "$DEFAULTS"; printf '%s\n' "${GH_TOKEN:+set}" "${VERCEL_TOKEN:+set}" "${CLOUDFLARE_API_TOKEN:+set}" \
      "${CLOUDFLARE_ACCOUNT_ID:-}" "${HEROKU_API_KEY:+set}" "${CLAUDE_CODE_OAUTH_TOKEN:+set}" \
      "${LORE_REMOTE:-}" "${TIMEZONE:-}" "${OPERATOR_NAME:-}" ) | {
    IFS= read -r D_GH; IFS= read -r D_VERCEL; IFS= read -r D_CF; IFS= read -r D_CFID; IFS= read -r D_HEROKU
    IFS= read -r D_CLAUDE; IFS= read -r D_LORE; IFS= read -r D_TZ; IFS= read -r D_OP
    echo "${dim}Using shared defaults from ${DEFAULTS}; leave a prompt blank to keep its default.${reset}"; echo
  }
fi
inherit() { [ -n "$1" ] && echo " ${dim}(default: set in defaults.conf)${reset}"; }

# ── Identity ────────────────────────────────────────────────────────────────
prompt AGENT_NAME "Agent name" "" "Slack display name (e.g. Ace, Jarvis, Scout)"
[ -n "$AGENT_NAME" ] || { echo "Agent name is required." >&2; exit 1; }
SLUG="$(slug "$AGENT_NAME")"
prompt CONF_FILE "Config filename" "${SLUG}.conf"
if [ -f "$CONF_FILE" ]; then
  printf "${bold}%s exists. Overwrite? [y/N]:${reset} " "$CONF_FILE" >&2; read -r yn
  case "$yn" in [yY]*) ;; *) echo "Aborted." >&2; exit 1 ;; esac
fi
echo
prompt VM_NAME   "exe.dev VM name" "${SLUG}-agent" "Reachable as <name>.exe.xyz; created by bootstrap.sh if missing"
prompt VM_CPU    "VM CPUs"   "2"
prompt VM_MEMORY "VM memory" "4GB"
prompt VM_DISK   "VM disk"   "20GB"

# ── Slack ───────────────────────────────────────────────────────────────────
echo
echo "${dim}Slack app: run './bootstrap.sh manifest ${CONF_FILE}' after this and paste the JSON at api.slack.com.${reset}"
prompt SLACK_MODE "Slack token mode (gateway|direct)" "gateway" "gateway = tokens held by an exe.dev Slack Bot integration, never on the VM; direct = tokens in ~/.enso/config.json"
prompt_secret SLACK_BOT_TOKEN "Slack Bot Token (xoxb-...)" "OAuth & Permissions → Bot User OAuth Token"
prompt_secret SLACK_APP_TOKEN "Slack App Token (xapp-...)" "Basic Information → App-Level Tokens (scope connections:write)"
prompt SLACK_OWNER_IDS "Your Slack member ID(s)" "" "U… ids that get an admin DM route (profile → ⋯ → Copy member ID); space/comma separated"
prompt NOTIFY_CHANNEL  "Notify channel ID" "" "Optional C… channel for job alerts and unsolicited messages"

# ── Claude ──────────────────────────────────────────────────────────────────
echo
prompt_secret CLAUDE_CODE_OAUTH_TOKEN "Claude Code OAuth token (sk-ant-oat01-...)" "From 'claude setup-token' on a machine with a browser. Blank = exe.dev's LLM gateway$(inherit "$D_CLAUDE")"

# ── Tools ───────────────────────────────────────────────────────────────────
echo; echo "${dim}Tool credentials — all optional; the CLIs are installed either way.${reset}"
prompt_secret GH_TOKEN             "GitHub token (gh + git push)" "$(inherit "$D_GH")"
prompt_secret VERCEL_TOKEN         "Vercel token" "$(inherit "$D_VERCEL")"
prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token (wrangler)" "$(inherit "$D_CF")"
if [ -n "$CLOUDFLARE_API_TOKEN" ]; then prompt CLOUDFLARE_ACCOUNT_ID "Cloudflare account ID" "$D_CFID"; else CLOUDFLARE_ACCOUNT_ID=""; fi
prompt_secret HEROKU_API_KEY       "Heroku API key" "$(inherit "$D_HEROKU")"

# ── Git / lore / machine ────────────────────────────────────────────────────
echo
prompt GIT_USER_NAME  "Git author name on the VM"  "${AGENT_NAME} (enso agent)"
prompt GIT_USER_EMAIL "Git author email on the VM" "${SLUG}-agent@users.noreply.github.com"
prompt LORE_REMOTE    "lore remote" "${D_LORE:-exedev@lore-host.exe.xyz:/srv/lore/repos}"
prompt LORE_CONTEXT   "lore context repo to attach now" "" "e.g. lore-jointly; blank to attach per workspace later"
prompt TIMEZONE       "VM timezone" "${D_TZ:-America/Vancouver}"
prompt OPERATOR_NAME  "Operator name (seeds docs/operator.md)" "${D_OP:-$(git config user.name 2>/dev/null || true)}"
prompt ENSO_REF       "enso git ref" "main"

# ── Write ───────────────────────────────────────────────────────────────────
umask 077
cat > "$CONF_FILE" <<CONF
# enso-agent-bootstrap config for ${AGENT_NAME}. SECRETS inside — gitignored, chmod 600.
# Field reference: agent.conf.example

AGENT_NAME="${AGENT_NAME}"
VM_NAME="${VM_NAME}"
VM_CPU=${VM_CPU}
VM_MEMORY=${VM_MEMORY}
VM_DISK=${VM_DISK}

SLACK_MODE="${SLACK_MODE}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN}"
SLACK_OWNER_IDS="${SLACK_OWNER_IDS}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL}"

CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}"

GH_TOKEN="${GH_TOKEN}"
VERCEL_TOKEN="${VERCEL_TOKEN}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID}"
HEROKU_API_KEY="${HEROKU_API_KEY}"

GIT_USER_NAME="${GIT_USER_NAME}"
GIT_USER_EMAIL="${GIT_USER_EMAIL}"

LORE_REMOTE="${LORE_REMOTE}"
LORE_CONTEXT="${LORE_CONTEXT}"

TIMEZONE="${TIMEZONE}"
OPERATOR_NAME="${OPERATOR_NAME}"

ENSO_REF="${ENSO_REF}"
BOOTSTRAP_REPO="https://github.com/nerdburn/enso-agent-bootstrap"
LORE_REPO="https://github.com/nerdburn/lore"
CONF

echo; echo "${bold}${cyan}Wrote ${CONF_FILE}${reset} (mode 600)"; echo
echo "Next:"
if [ -z "$SLACK_BOT_TOKEN" ]; then
  echo "  1. ${bold}./bootstrap.sh manifest ${CONF_FILE}${reset}   → create the Slack app, paste both tokens into ${CONF_FILE}"
  echo "  2. ${bold}./bootstrap.sh up ${CONF_FILE}${reset}         → creates the VM, installs and starts the agent"
else
  echo "  1. ${bold}./bootstrap.sh up ${CONF_FILE}${reset}         → creates the VM, installs and starts the agent"
fi
