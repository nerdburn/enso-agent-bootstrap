#!/usr/bin/env bash
# enso-agent-bootstrap — install.sh
#
# Runs ON the exe.dev VM (as the login user, with passwordless sudo) and turns
# it into a fully configured enso Slack agent. Idempotent: re-run it to update
# enso, refresh tools, or finish an interrupted install. Configuration that
# already exists in ~/.enso is never rewritten.
#
# Usage:
#   ./install.sh agent.conf              # full install from a conf file
#   ./install.sh --conf - < agent.conf   # conf over stdin (what bootstrap.sh does)
#   ./install.sh --tools-only            # CLIs + enso checkout + lore, no config
#   ./install.sh --manifest [--name X]   # print the Slack app manifest JSON
#   AGENT_NAME=Ace SLACK_BOT_TOKEN=… ./install.sh    # conf via environment
#
# What a full run does:
#   1. apt + Node check, timezone, git identity
#   2. CLIs: claude, gh, vercel, wrangler, heroku, lore (built from source)
#   3. enso: clone/update ~/apps/enso at ENSO_REF, venv, pip install .[slack,web]
#      (+ vendored Slack-gateway patch when SLACK_MODE=gateway)
#   4. secrets: ~/.enso/secrets/{claude,tools}.env (mode 600); Slack tokens stay
#      in the exe.dev Slack Bot integration unless SLACK_MODE=direct
#   5. fresh enso setup (non-interactive) → ~/.enso, DM routes, baseline commit
#   6. house customizations: root AGENTS.md section, operator.md, lore skills
#   7. lore: ~/.lore/config.json, SSH key for the lore host, optional MCP wiring
#   8. systemd --user service + linger, config check, status
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Arguments ────────────────────────────────────────────────────────────────
CONF=""; TOOLS_ONLY=false; PRINT_MANIFEST=false; MANIFEST_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)        CONF="${2:-}"; shift 2 ;;
    --tools-only)  TOOLS_ONLY=true; shift ;;
    --manifest)    PRINT_MANIFEST=true; shift ;;
    --name)        MANIFEST_NAME="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             CONF="$1"; shift ;;
  esac
done

if [ -n "$CONF" ]; then
  if [ "$CONF" = "-" ]; then
    TMPCONF="$(mktemp)"; chmod 600 "$TMPCONF"; cat > "$TMPCONF"
    trap 'rm -f "$TMPCONF"' EXIT
    # shellcheck disable=SC1090
    source "$TMPCONF"
  else
    [ -f "$CONF" ] || die "config not found: $CONF"
    # shellcheck disable=SC1090
    source "$CONF"
  fi
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
AGENT_NAME="${AGENT_NAME:-${MANIFEST_NAME:-Enso}}"
VM_NAME="${VM_NAME:-$(hostname -s 2>/dev/null || echo vm)}"
SLACK_MODE="${SLACK_MODE:-gateway}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
SLACK_OWNER_IDS="${SLACK_OWNER_IDS:-}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
GH_TOKEN="${GH_TOKEN:-}"; VERCEL_TOKEN="${VERCEL_TOKEN:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"; CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
HEROKU_API_KEY="${HEROKU_API_KEY:-}"
GIT_USER_NAME="${GIT_USER_NAME:-${AGENT_NAME} (enso agent)}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')-agent@users.noreply.github.com}"
LORE_REMOTE="${LORE_REMOTE:-exedev@lore-host.exe.xyz:/srv/lore/repos}"
LORE_CONTEXT="${LORE_CONTEXT:-}"
TIMEZONE="${TIMEZONE:-}"
OPERATOR_NAME="${OPERATOR_NAME:-}"
ENSO_REF="${ENSO_REF:-main}"
LORE_REPO="${LORE_REPO:-https://github.com/nerdburn/lore}"
ENSO_DIR="$HOME/apps/enso"
LORE_DIR="$HOME/apps/lore"
ENSO_BIN="$ENSO_DIR/.venv/bin/enso"
ENSO_PY="$ENSO_DIR/.venv/bin/python"
GATEWAY_URL="https://${VM_NAME}.int.exe.xyz/api/"

# ── --manifest ───────────────────────────────────────────────────────────────
if [ "$PRINT_MANIFEST" = true ]; then
  sed "s/__AGENT_NAME__/${AGENT_NAME}/g" "$HERE/lib/slack-manifest.json"
  echo >&2
  echo "↑ Paste at https://api.slack.com/apps?new_app=1 → From an app manifest (JSON)." >&2
  exit 0
fi

[ "$(uname -s)" = "Linux" ] || die "install.sh runs on the Linux VM, not your laptop (use bootstrap.sh there)"
export DEBIAN_FRONTEND=noninteractive

# ── 1. Base system ───────────────────────────────────────────────────────────
log "base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq python3-venv python3-pip git curl jq ca-certificates >/dev/null

if ! have node || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  info "installing Node 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs >/dev/null
fi
info "node $(node --version), python $(python3 --version | awk '{print $2}')"

CUR_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
if [ -n "$TIMEZONE" ] && [ "$CUR_TZ" != "$TIMEZONE" ]; then
  info "timezone → $TIMEZONE"
  sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null \
    || { sudo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; echo "$TIMEZONE" | sudo tee /etc/timezone >/dev/null; }
fi

git config --global init.defaultBranch main
git config --global user.name  "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# ── 2. CLIs ──────────────────────────────────────────────────────────────────
log "agent CLIs"
if ! have claude; then
  info "installing claude"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null
  export PATH="$HOME/.local/bin:$PATH"
fi
have claude || die "claude CLI not on PATH after install"

if ! have gh; then
  info "installing gh"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh >/dev/null
fi

if ! have heroku; then
  info "installing heroku"
  curl -fsSL https://cli-assets.heroku.com/install.sh | sudo sh >/dev/null 2>&1
fi

NPM_GLOBAL=()
have vercel   || NPM_GLOBAL+=(vercel)
have wrangler || NPM_GLOBAL+=(wrangler)
if [ ${#NPM_GLOBAL[@]} -gt 0 ]; then
  info "npm install -g ${NPM_GLOBAL[*]}"
  sudo npm install -g --no-fund --no-audit "${NPM_GLOBAL[@]}" >/dev/null
fi

# lore: built from source (the npm package excludes plugins/, which we need
# for the skills), packed, then installed globally — the same path the lore
# runbook uses for VMs.
log "lore (project memory CLI)"
if [ -d "$LORE_DIR/.git" ]; then
  git -C "$LORE_DIR" pull -q --ff-only || warn "could not fast-forward $LORE_DIR; using existing checkout"
else
  mkdir -p "$(dirname "$LORE_DIR")"
  git clone -q "$LORE_REPO" "$LORE_DIR"
fi
LORE_HEAD="$(git -C "$LORE_DIR" rev-parse --short HEAD)"
if ! have lore || [ "$(cat "$LORE_DIR/.installed-rev" 2>/dev/null)" != "$LORE_HEAD" ]; then
  info "building lore @ $LORE_HEAD"
  ( cd "$LORE_DIR" && (npm ci --no-fund --no-audit >/dev/null 2>&1 || npm install --no-fund --no-audit >/dev/null) \
      && rm -f ./*.tgz && npm pack --silent >/dev/null )
  sudo npm install -g --no-fund --no-audit "$LORE_DIR"/nerdburn-lore-*.tgz >/dev/null
  echo "$LORE_HEAD" > "$LORE_DIR/.installed-rev"
fi
info "lore $(lore --version 2>/dev/null || echo '?')"

for t in claude gh vercel wrangler heroku lore; do
  have "$t" && info "✓ $t → $(command -v "$t")" || warn "$t missing"
done

# ── 3. enso ──────────────────────────────────────────────────────────────────
log "enso ($ENSO_REF)"
if [ -d "$ENSO_DIR/.git" ]; then
  git -C "$ENSO_DIR" fetch -q origin
  # Drop any locally applied patch before moving the checkout, re-applied below.
  git -C "$ENSO_DIR" checkout -q -- . 2>/dev/null || true
  git -C "$ENSO_DIR" checkout -q "$ENSO_REF"
  git -C "$ENSO_DIR" pull -q --ff-only origin "$ENSO_REF" 2>/dev/null || true
else
  mkdir -p "$(dirname "$ENSO_DIR")"
  git clone -q https://github.com/geekforbrains/enso "$ENSO_DIR"
  git -C "$ENSO_DIR" checkout -q "$ENSO_REF"
fi
info "enso @ $(git -C "$ENSO_DIR" log --oneline -1)"

if [ "$SLACK_MODE" = "gateway" ]; then
  PATCH="$HERE/patches/0001-slack-api-gateway.patch"
  if grep -q "ENSO_SLACK_API_BASE_URL" "$ENSO_DIR/src/enso/transports/slack.py"; then
    info "gateway support already present"
  elif git -C "$ENSO_DIR" apply --check "$PATCH" 2>/dev/null; then
    git -C "$ENSO_DIR" apply "$PATCH"; info "applied $(basename "$PATCH")"
  else
    die "SLACK_MODE=gateway but the vendored patch no longer applies to enso $ENSO_REF; use SLACK_MODE=direct or refresh the patch"
  fi
fi

[ -x "$ENSO_PY" ] || python3 -m venv "$ENSO_DIR/.venv"
"$ENSO_PY" -m pip install -q --upgrade pip
"$ENSO_PY" -m pip install -q -e "$ENSO_DIR[slack,web]"
info "$("$ENSO_BIN" --version)"

if [ "$TOOLS_ONLY" = true ]; then
  log "tools-only run complete"
  info "next: ./install.sh <agent.conf>   (or let the agent on this VM do it — see AGENTS.md)"
  exit 0
fi

# ── 4. Secrets ───────────────────────────────────────────────────────────────
if [ "$SLACK_MODE" = "gateway" ]; then
  log "slack gateway preflight ($GATEWAY_URL)"
  GW_AUTH="$(curl -s -m 20 -X POST "${GATEWAY_URL}auth.test" || true)"
  if ! printf '%s' "$GW_AUTH" | jq -e '.ok == true' >/dev/null 2>&1; then
    warn "auth.test via the gateway did not return ok: ${GW_AUTH:-<no response>}"
    die "no exe.dev Slack Bot integration named '$VM_NAME' is attached to this VM. From your laptop:
       printf '%s\n%s\n' \"\$SLACK_BOT_TOKEN\" \"\$SLACK_APP_TOKEN\" | ssh exe.dev integrations add slack --name=$VM_NAME --bot-token=- --app-token=- --attach vm:$VM_NAME
     (or: ./bootstrap.sh slack-integration <conf>). Then re-run install.sh."
  fi
  info "gateway ok: bot $(printf '%s' "$GW_AUTH" | jq -r .user) in $(printf '%s' "$GW_AUTH" | jq -r .team)"
fi
log "secrets → ~/.enso/secrets"
[ -n "$SLACK_OWNER_IDS" ] || die "SLACK_OWNER_IDS is required (your Slack member ID, U...)"
umask 077
mkdir -p "$HOME/.enso/secrets"; chmod 700 "$HOME/.enso" "$HOME/.enso/secrets"

if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "$HOME/.enso/secrets/claude.env"
  info "claude: subscription OAuth token"
else
  printf 'ANTHROPIC_BASE_URL=https://llm.int.exe.xyz\nANTHROPIC_API_KEY=implicit\n' > "$HOME/.enso/secrets/claude.env"
  info "claude: exe.dev LLM gateway (no CLAUDE_CODE_OAUTH_TOKEN given)"
fi

{
  echo "# Tool credentials; loaded by 'enso serve' and inherited by the admin agent."
  [ -n "$GH_TOKEN" ]              && echo "GH_TOKEN=$GH_TOKEN"
  [ -n "$VERCEL_TOKEN" ]          && echo "VERCEL_TOKEN=$VERCEL_TOKEN"
  [ -n "$CLOUDFLARE_API_TOKEN" ]  && echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ] && echo "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID"
  [ -n "$HEROKU_API_KEY" ]        && echo "HEROKU_API_KEY=$HEROKU_API_KEY"
  true
} > "$HOME/.enso/secrets/tools.env"
chmod 600 "$HOME"/.enso/secrets/*.env

# Make the same credentials usable from an interactive shell on the VM too.
if [ -n "$GH_TOKEN" ]; then
  GH_TOKEN="$GH_TOKEN" gh auth setup-git >/dev/null 2>&1 || true
  info "gh: token + git credential helper"
fi
if [ -n "$VERCEL_TOKEN" ]; then
  mkdir -p "$HOME/.local/share/com.vercel.cli"
  printf '{"token":"%s"}\n' "$VERCEL_TOKEN" > "$HOME/.local/share/com.vercel.cli/auth.json"
  info "vercel: token"
fi
if [ -n "$HEROKU_API_KEY" ]; then
  git config --global credential.https://git.heroku.com.helper '!heroku git:credentials'
  info "heroku: token + git credential helper"
fi
umask 022

# ── 5. Fresh enso setup ──────────────────────────────────────────────────────
log "enso setup (non-interactive)"
export AGENT_NAME SLACK_MODE SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_OWNER_IDS NOTIFY_CHANNEL
[ "$SLACK_MODE" = "gateway" ] && export ENSO_SLACK_API_BASE_URL="$GATEWAY_URL"
"$ENSO_PY" "$HERE/lib/configure_enso.py"

# Keep a renamed copy of the manifest next to the config for future re-pastes
# (excluded from ~/.enso's local history without touching enso's managed block).
sed "s/__AGENT_NAME__/${AGENT_NAME}/g" "$HERE/lib/slack-manifest.json" > "$HOME/.enso/slack-app-manifest.json"
EXCL="$HOME/.enso/.git/info/exclude"
if [ -d "$HOME/.enso/.git" ] && ! grep -qs '^/slack-app-manifest.json$' "$EXCL"; then
  mkdir -p "$(dirname "$EXCL")"; echo '/slack-app-manifest.json' >> "$EXCL"
fi

# ── 6. House customizations ──────────────────────────────────────────────────
log "house customizations"
render() {  # render <template> → stdout with placeholders substituted
  sed -e "s|__AGENT_NAME__|${AGENT_NAME}|g" -e "s|__VM_NAME__|${VM_NAME}|g" \
      -e "s|__OPERATOR_NAME__|${OPERATOR_NAME:-unknown}|g" -e "s|__TIMEZONE__|${TIMEZONE:-UTC}|g" \
      -e "s|__SLACK_OWNER_IDS__|${SLACK_OWNER_IDS}|g" "$1"
}
CHANGED=()
if ! grep -q "enso-agent-bootstrap:house" "$HOME/.enso/AGENTS.md"; then
  render "$HERE/templates/AGENTS.house.md" >> "$HOME/.enso/AGENTS.md"
  CHANGED+=(AGENTS.md); info "appended house section to ~/.enso/AGENTS.md"
fi
if [ -n "$OPERATOR_NAME" ] && grep -q "No confirmed facts yet" "$HOME/.enso/docs/operator.md" 2>/dev/null \
   && ! grep -q "$OPERATOR_NAME" "$HOME/.enso/docs/operator.md"; then
  render "$HERE/templates/operator.md" > "$HOME/.enso/docs/operator.md"
  CHANGED+=(docs/operator.md); info "seeded docs/operator.md"
fi
for skill in lore-mcp lore-onboard; do
  if [ ! -d "$HOME/.enso/skills/$skill" ] && [ -d "$LORE_DIR/plugins/lore/skills/$skill" ]; then
    cp -R "$LORE_DIR/plugins/lore/skills/$skill" "$HOME/.enso/skills/$skill"
    CHANGED+=("skills/$skill"); info "installed skill $skill"
  fi
done
if [ ${#CHANGED[@]} -gt 0 ]; then
  git -C "$HOME/.enso" add "${CHANGED[@]}"
  git -C "$HOME/.enso" commit -q -m "bootstrap: house instructions, operator doc, lore skills" || true
fi

# ── 7. lore wiring ───────────────────────────────────────────────────────────
log "lore wiring"
mkdir -p "$HOME/.lore"
[ -f "$HOME/.lore/config.json" ] || printf '{ "remote": "%s" }\n' "$LORE_REMOTE" > "$HOME/.lore/config.json"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "${VM_NAME}-lore-access" -f "$HOME/.ssh/id_ed25519"
fi
LORE_HOST="${LORE_REMOTE#*@}"; LORE_HOST="${LORE_HOST%%:*}"
if ! grep -q "Host $LORE_HOST" "$HOME/.ssh/config" 2>/dev/null; then
  printf 'Host %s\n  StrictHostKeyChecking accept-new\n' "$LORE_HOST" >> "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
fi
if [ -n "$LORE_CONTEXT" ]; then
  if ! claude mcp get lore >/dev/null 2>&1; then
    claude mcp add --scope user lore -- "$(command -v lore)" mcp --context "$LORE_CONTEXT" >/dev/null
    info "registered MCP server 'lore' (--context $LORE_CONTEXT) for the admin agent"
  fi
fi

# ── 8. Service ───────────────────────────────────────────────────────────────
log "systemd service"
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
"$ENSO_BIN" service install >/dev/null 2>&1 || true
UNIT_DIR="$HOME/.config/systemd/user"; DROPIN="$UNIT_DIR/enso.service.d/bootstrap.conf"
mkdir -p "$(dirname "$DROPIN")"
{
  echo "[Service]"
  echo "Environment=PATH=$HOME/.local/bin:$ENSO_DIR/.venv/bin:/usr/local/bin:/usr/bin:/bin"
  [ "$SLACK_MODE" = "gateway" ] && echo "Environment=ENSO_SLACK_API_BASE_URL=$GATEWAY_URL"
  true
} > "$DROPIN"
if [ "$SLACK_MODE" = "gateway" ] && ! grep -qs "ENSO_SLACK_API_BASE_URL" "$HOME/.bashrc"; then
  printf '\n# enso-agent-bootstrap: route `enso slack …` through the exe.dev Slack gateway\nexport ENSO_SLACK_API_BASE_URL=%s\n' "$GATEWAY_URL" >> "$HOME/.bashrc"
fi
systemctl --user daemon-reload
systemctl --user enable enso.service >/dev/null 2>&1 || true
systemctl --user restart enso.service
sleep 4
STATE="$(systemctl --user is-active enso.service || true)"
info "enso.service: $STATE"
[ "$STATE" = "active" ] || journalctl --user -u enso.service --no-pager -n 20 | sed 's/^/        /'

log "enso config check"
"$ENSO_BIN" config check 2>&1 | sed 's/^/    /' || warn "config check reported problems (see above)"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
printf '\033[1;32m✅ %s is set up on %s.exe.xyz\033[0m\n' "$AGENT_NAME" "$VM_NAME"
cat <<SUMMARY
   DM the bot in Slack as one of: $SLACK_OWNER_IDS
   status:  systemctl --user status enso.service
   logs:    journalctl --user -u enso.service -f
   config:  ~/.enso/config.json   (routes under transports.slack)
   slack:   $([ "$SLACK_MODE" = gateway ] && echo "tokens held by exe.dev integration '$VM_NAME' ($GATEWAY_URL)" || echo "tokens in config.json (direct mode)")

   Still human, once:
   • lore access — register this VM's key with the lore host (from your laptop):
       ssh exe.dev ssh-key add --tag=lore "$(cat "$HOME/.ssh/id_ed25519.pub")"
     (bootstrap.sh lore-key <conf> does exactly this)
   • invite the bot to any channel you want to route, then add the route
     (see the house section of ~/.enso/AGENTS.md or ask the agent to do it)
SUMMARY
