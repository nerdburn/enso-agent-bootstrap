#!/usr/bin/env bash
# enso-agent-bootstrap — install.sh
#
# Runs ON the exe.dev VM (as the login user, with passwordless sudo) and turns
# it into a configured enso 0.4 Slack agent, set up the way abby-agent is.
# Idempotent: re-run it to refresh tools, add channels, or finish an interrupted
# install. An existing config.json is never replaced, only extended.
#
# Usage:
#   ./install.sh agent.conf              # full install from a conf file
#   ./install.sh --conf - < agent.conf   # conf over stdin (what bootstrap.sh does)
#   ./install.sh --migrate agent.conf    # move an enso 2.x-fork (or older) home aside, then install
#   ./install.sh --tools-only            # CLIs + enso runtime + lore, no config
#   ./install.sh --manifest [--name X]   # print the Slack app manifest JSON
#
# What a full run does:
#   1. apt + Node, timezone, git identity
#   2. CLIs: claude, gh (+ exe.dev GitHub wrapper), vercel, wrangler, heroku, lore
#   3. enso: the official managed release (ENSO_VERSION) → ~/.local/bin/enso,
#      runtime inside ENSO_HOME; `enso init`
#      (--migrate: stop the old service, back up and move the old home first)
#   4. tool tokens → ~/.config/enso-agent/env, loaded by the service
#   5. project checkout (PROJECT_REPO, via github.int.exe.xyz)
#   6. lib/configure_enso.py: Slack tokens checked, channels resolved/joined,
#      full-access channel workspace with lore over the lore-mcp integration,
#      config.json applied through `enso config apply` / `config set`
#   7. house layer: identity + tools in AGENTS.md, operator workspace and
#      knowledge note, lore skills, admin lore MCP
#   8. `enso service install` + linger, config check, doctor, summary
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; [ -n "${LEGACY_HOME:-}" ] && rollback_hint; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rollback_hint() { :; }   # redefined once --migrate has moved the old home

# ── Arguments ────────────────────────────────────────────────────────────────
CONF=""; TOOLS_ONLY=false; PRINT_MANIFEST=false; MANIFEST_NAME=""; MIGRATE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)        CONF="${2:-}"; shift 2 ;;
    --tools-only)  TOOLS_ONLY=true; shift ;;
    --migrate)     MIGRATE=true; shift ;;
    --manifest)    PRINT_MANIFEST=true; shift ;;
    --name)        MANIFEST_NAME="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             CONF="$1"; shift ;;
  esac
done

TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}" 2>/dev/null || true; }
trap cleanup EXIT
if [ -n "$CONF" ]; then
  if [ "$CONF" = "-" ]; then
    TMPCONF="$(mktemp)"; chmod 600 "$TMPCONF"; TMPFILES+=("$TMPCONF"); cat > "$TMPCONF"
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
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
SLACK_OWNER_IDS="${SLACK_OWNER_IDS:-}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
CHANNELS="${CHANNELS:-}"
CHANNEL_WORKSPACE="${CHANNEL_WORKSPACE:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
CLAUDE_AUTH="${CLAUDE_AUTH:-subscription}"
GH_TOKEN="${GH_TOKEN:-}"; VERCEL_TOKEN="${VERCEL_TOKEN:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"; CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
HEROKU_API_KEY="${HEROKU_API_KEY:-}"
GITHUB_INTEGRATIONS="${GITHUB_INTEGRATIONS:-}"
PROJECT_REPO="${PROJECT_REPO:-}"
PROJECT_DIR="${PROJECT_DIR:-${PROJECT_REPO:+$HOME/apps/${PROJECT_REPO##*/}}}"
GH_BOT_EMAIL="267204973+exe-dev-github-integration[bot]@users.noreply.github.com"
GIT_USER_NAME="${GIT_USER_NAME:-${AGENT_NAME} (Enso agent)}"
if [ -n "$GITHUB_INTEGRATIONS" ]; then GIT_EMAIL_DEFAULT="$GH_BOT_EMAIL"
else GIT_EMAIL_DEFAULT="$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')-agent@users.noreply.github.com"; fi
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$GIT_EMAIL_DEFAULT}"
LORE_REMOTE="${LORE_REMOTE:-exedev@lore-host.exe.xyz:/srv/lore/repos}"
LORE_CONTEXT="${LORE_CONTEXT:-}"
LORE_MCP_URL="${LORE_MCP_URL:-https://lore-mcp.int.exe.xyz/mcp}"
TIMEZONE="${TIMEZONE:-}"
OPERATOR_NAME="${OPERATOR_NAME:-}"
DEFAULT_MODEL="${DEFAULT_MODEL:-opus}"
DEFAULT_EFFORT="${DEFAULT_EFFORT:-high}"
ENSO_VERSION="${ENSO_VERSION:-0.4.0}"
ENSO_HOME="${ENSO_HOME:-$HOME/.enso}"
LORE_REPO="${LORE_REPO:-https://github.com/nerdburn/lore}"
LORE_DIR="$HOME/apps/lore"
ENSO_BIN="$HOME/.local/bin/enso"
AGENT_ENV="$HOME/.config/enso-agent/env"
export PATH="$HOME/.local/bin:$PATH"
# Knobs from the enso 2.x bootstrap that no longer mean anything.
[ -n "${SLACK_MODE:-}" ] && [ "${SLACK_MODE}" != "direct" ] && info "SLACK_MODE=${SLACK_MODE} ignored: enso 0.4 keeps the Slack tokens in config.json"
[ -n "${ENSO_REF:-}${ENSO_REPO:-}" ] && info "ENSO_REPO/ENSO_REF ignored: enso comes from the official release (ENSO_VERSION=$ENSO_VERSION)"

# ── --manifest ───────────────────────────────────────────────────────────────
if [ "$PRINT_MANIFEST" = true ]; then
  sed "s/__AGENT_NAME__/${AGENT_NAME}/g" "$HERE/lib/slack-manifest.json"
  echo >&2
  echo "↑ Paste at https://api.slack.com/apps?new_app=1 → From an app manifest (JSON)." >&2
  exit 0
fi

[ "$(uname -s)" = "Linux" ] || die "install.sh runs on the Linux VM, not your laptop (use bootstrap.sh there)"
export DEBIAN_FRONTEND=noninteractive
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# Which kind of home is at ENSO_HOME? fresh | current (0.4 config) | legacy (2.x fork or older)
home_kind() {
  [ -f "$ENSO_HOME/config.json" ] || { echo fresh; return; }
  if jq -e '.version == 2' "$ENSO_HOME/config.json" >/dev/null 2>&1; then echo current; else echo legacy; fi
}

# ── 1. Base system ───────────────────────────────────────────────────────────
log "base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq python3 git curl jq ca-certificates >/dev/null

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
mkdir -p "$HOME/.local/bin"
if ! have claude; then
  info "installing claude"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null
fi
have claude || die "claude CLI not on PATH after install"

REAL_GH="$(type -ap gh 2>/dev/null | grep -v "^$HOME/.local/bin/" | head -1 || true)"
if [ -z "$REAL_GH" ]; then
  info "installing gh"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh >/dev/null
  REAL_GH="$(type -ap gh | grep -v "^$HOME/.local/bin/" | head -1)"
fi
# The exe.dev GitHub integration injects credentials at github.int.exe.xyz;
# this wrapper points gh at it, the way abby-agent is set up.
if [ -n "$GITHUB_INTEGRATIONS" ]; then
  printf '#!/bin/sh\nexport GH_HOST="${GH_HOST:-github.int.exe.xyz}"\nexec %s "$@"\n' "$REAL_GH" > "$HOME/.local/bin/gh"
  chmod 755 "$HOME/.local/bin/gh"
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

# lore: built from source (the npm package excludes plugins/, which holds the skills).
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

for t in claude codex gh vercel wrangler heroku lore; do
  have "$t" && info "✓ $t → $(command -v "$t")" || warn "$t missing"
done

# ── 3. enso ──────────────────────────────────────────────────────────────────
KIND="$(home_kind)"
LEGACY_HOME=""
if [ "$KIND" = legacy ] && [ "$MIGRATE" != true ]; then
  if [ "$TOOLS_ONLY" = true ]; then
    warn "$ENSO_HOME holds a pre-0.4 enso home; skipping the enso runtime (use --migrate)"
    log "tools-only run complete"; exit 0
  fi
  die "$ENSO_HOME holds a pre-0.4 enso home (enso 2.x fork or older). enso 0.4 cannot upgrade it in place.
       Re-run with --migrate: it stops the old service, backs the home up, moves it aside, and installs fresh."
fi
RESUME_LEGACY=""
if [ "$MIGRATE" = true ] && [ "$KIND" != legacy ]; then
  # A migration that stopped after moving the old home resumes from it.
  if [ -f "$HOME/.enso-legacy-path" ] && [ -f "$(cat "$HOME/.enso-legacy-path")/config.json" ]; then
    RESUME_LEGACY="$(cat "$HOME/.enso-legacy-path")"; info "--migrate: resuming from $RESUME_LEGACY"
  else
    info "--migrate: $ENSO_HOME is not a legacy home; installing normally"
  fi
  MIGRATE=false
fi
if [ -n "$RESUME_LEGACY" ]; then
  LEGACY_VARS="$(mktemp)"; chmod 600 "$LEGACY_VARS"; TMPFILES+=("$LEGACY_VARS")
  SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_APP_TOKEN="$SLACK_APP_TOKEN" SLACK_OWNER_IDS="$SLACK_OWNER_IDS" \
  CHANNELS="$CHANNELS" CHANNEL_WORKSPACE="$CHANNEL_WORKSPACE" LORE_CONTEXT="$LORE_CONTEXT" NOTIFY_CHANNEL="$NOTIFY_CHANNEL" \
    python3 "$HERE/lib/read_legacy.py" "$RESUME_LEGACY" > "$LEGACY_VARS"
  # shellcheck disable=SC1090
  source "$LEGACY_VARS"
  LEGACY_HOME="$RESUME_LEGACY"; BACKUP="(from the first attempt, in ~/backups)"
fi

if [ "$MIGRATE" = true ]; then
  [ "$TOOLS_ONLY" = true ] && die "--migrate needs a conf, not --tools-only"
  log "migrate: reading the legacy home"
  LEGACY_VARS="$(mktemp)"; chmod 600 "$LEGACY_VARS"; TMPFILES+=("$LEGACY_VARS")
  SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_APP_TOKEN="$SLACK_APP_TOKEN" SLACK_OWNER_IDS="$SLACK_OWNER_IDS" \
  CHANNELS="$CHANNELS" CHANNEL_WORKSPACE="$CHANNEL_WORKSPACE" LORE_CONTEXT="$LORE_CONTEXT" NOTIFY_CHANNEL="$NOTIFY_CHANNEL" \
    python3 "$HERE/lib/read_legacy.py" "$ENSO_HOME" > "$LEGACY_VARS"
  # shellcheck disable=SC1090
  source "$LEGACY_VARS"
  info "carried over: $(cut -d= -f1 "$LEGACY_VARS" | grep -v TOKEN | tr '\n' ' ')$(grep -q TOKEN "$LEGACY_VARS" && echo '+ Slack tokens')"
  # Prove the tokens before anything stops.
  AUTH="$(curl -s -m 20 -H "Authorization: Bearer $SLACK_BOT_TOKEN" -X POST https://slack.com/api/auth.test || true)"
  printf '%s' "$AUTH" | jq -e '.ok == true' >/dev/null 2>&1 \
    || die "Slack rejected the bot token ($(printf '%s' "$AUTH" | jq -r '.error // "no response"')); nothing was changed"

  TS="$(date +%Y%m%d-%H%M%S)"
  LEGACY_HOME="${ENSO_HOME}-legacy-$TS"
  BACKUP="$HOME/backups/enso-legacy-$TS.tar.gz"
  rollback_hint() {
    warn "migration stopped. To go back to the old agent:"
    warn "  systemctl --user stop enso.service; rm -rf '$ENSO_HOME'; mv '$LEGACY_HOME' '$ENSO_HOME'"
    warn "  then restore the old unit (backup in $BACKUP) and: systemctl --user daemon-reload && systemctl --user restart enso.service"
  }
  log "migrate: stopping the old service"
  systemctl --user stop enso.service 2>/dev/null || true
  systemctl --user disable enso.service >/dev/null 2>&1 || true
  if [ -f /etc/systemd/system/enso.service ]; then
    sudo systemctl stop enso.service 2>/dev/null || true
    sudo systemctl disable enso.service >/dev/null 2>&1 || true
    sudo mv /etc/systemd/system/enso.service "/etc/systemd/system/enso.service.legacy-$TS"
    sudo systemctl daemon-reload
    info "system unit enso.service disabled (kept as enso.service.legacy-$TS)"
  fi
  sleep 2
  if pgrep -u "$USER" -f "enso serve" >/dev/null; then
    die "an old 'enso serve' is still running ($(pgrep -u "$USER" -af 'enso serve' | head -1)); stop it and re-run. Nothing was moved"
  fi
  log "migrate: backing up $ENSO_HOME → $BACKUP"
  mkdir -p "$HOME/backups"; chmod 700 "$HOME/backups"
  tar czf "$BACKUP" -C "$HOME" --exclude='*/node_modules' --exclude='*/.next' --exclude='*/.venv' \
      "$(realpath --relative-to="$HOME" "$ENSO_HOME")" $( [ -d "$HOME/.config/systemd/user" ] && echo .config/systemd/user )
  chmod 600 "$BACKUP"
  mv "$ENSO_HOME" "$LEGACY_HOME"
  echo "$LEGACY_HOME" > "$HOME/.enso-legacy-path"
  trap 'rollback_hint; exit 1' ERR
  info "old home moved to $LEGACY_HOME"
  # The 2.x bootstrap's gateway drop-in and shell export would confuse the new service.
  rm -f "$HOME/.config/systemd/user/enso.service.d/bootstrap.conf"
  sed -i '/enso-agent-bootstrap: route `enso slack …` through the exe.dev Slack gateway/d; /^export ENSO_SLACK_API_BASE_URL=/d' "$HOME/.bashrc" 2>/dev/null || true
fi

log "enso $ENSO_VERSION (official release)"
INSTALLED="$(jq -r '.version // empty' "$ENSO_HOME/runtime/install.json" 2>/dev/null || true)"
if [ -z "$INSTALLED" ]; then
  # An older enso's launcher (often a symlink into its venv) blocks the release
  # installer; keep it beside the new one.
  if [ -e "$ENSO_BIN" ] || [ -L "$ENSO_BIN" ]; then
    if ! grep -qs "Enso managed launcher" "$ENSO_BIN"; then
      mv "$ENSO_BIN" "$ENSO_BIN.legacy-$(date +%Y%m%d-%H%M%S)"; info "moved the old unmanaged enso launcher aside"
    fi
  fi
  if [ "$ENSO_VERSION" = latest ]; then URL="https://github.com/geekforbrains/enso/releases/latest/download/install.sh"
  else URL="https://github.com/geekforbrains/enso/releases/download/v${ENSO_VERSION}/install.sh"; fi
  curl -fsSL "$URL" | sh -s -- --home "$ENSO_HOME" --extras slack,web >/dev/null
  INSTALLED="$(jq -r .version "$ENSO_HOME/runtime/install.json")"
  info "installed enso $INSTALLED (managed runtime in $ENSO_HOME/runtime)"
elif [ "$ENSO_VERSION" != latest ] && [ "$INSTALLED" != "$ENSO_VERSION" ]; then
  warn "enso $INSTALLED is installed, not $ENSO_VERSION. Upgrades go through enso itself:"
  warn "  enso update check && enso update apply   (snapshotted, rolls back on failure)"
else
  info "enso $INSTALLED already installed"
fi
[ -x "$ENSO_BIN" ] || die "the managed enso launcher is missing at $ENSO_BIN"
"$ENSO_BIN" init --json >/dev/null || die "enso init failed; run \`$ENSO_BIN init\` to see why"

if [ "$TOOLS_ONLY" = true ]; then
  log "tools-only run complete"
  info "next: ./install.sh <agent.conf>   (or let the agent on this VM do it — see AGENTS.md)"
  exit 0
fi
[ -n "$SLACK_OWNER_IDS" ] || die "SLACK_OWNER_IDS is required (your Slack member ID, U...)"

# ── 4. Tool tokens and Claude auth ───────────────────────────────────────────
log "credentials → $AGENT_ENV"
umask 077
mkdir -p "$(dirname "$AGENT_ENV")"
CLAUDE_LOGIN_NEEDED=false
{
  echo "# enso-agent-bootstrap: loaded by enso.service (drop-in 10-agent-env.conf). Mode 600."
  case "$CLAUDE_AUTH" in
    subscription) [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" ;;
    exe-gateway)  printf 'ANTHROPIC_BASE_URL=https://llm.int.exe.xyz\nANTHROPIC_API_KEY=implicit\n' ;;
    *) die "CLAUDE_AUTH must be 'subscription' or 'exe-gateway' (got '$CLAUDE_AUTH')" ;;
  esac
  [ -n "$GH_TOKEN" ] && [ -z "$GITHUB_INTEGRATIONS" ] && echo "GH_TOKEN=$GH_TOKEN"
  [ -n "$VERCEL_TOKEN" ]          && echo "VERCEL_TOKEN=$VERCEL_TOKEN"
  [ -n "$CLOUDFLARE_API_TOKEN" ]  && echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ] && echo "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID"
  [ -n "$HEROKU_API_KEY" ]        && echo "HEROKU_API_KEY=$HEROKU_API_KEY"
  true
} > "$AGENT_ENV"
chmod 600 "$AGENT_ENV"
if [ "$CLAUDE_AUTH" = subscription ] && [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  if [ -f "$HOME/.claude/.credentials.json" ]; then info "claude: subscription (logged in on this VM)"
  else CLAUDE_LOGIN_NEEDED=true; warn "claude: no token in the conf and no login on this VM yet (see the summary)"; fi
else
  info "claude: $([ "$CLAUDE_AUTH" = exe-gateway ] && echo 'exe.dev LLM gateway (CLAUDE_AUTH=exe-gateway)' || echo 'subscription (OAuth token from the conf)')"
fi
if [ -n "$GH_TOKEN" ] && [ -z "$GITHUB_INTEGRATIONS" ]; then
  GH_TOKEN="$GH_TOKEN" gh auth setup-git >/dev/null 2>&1 || true; info "gh: token + git credential helper"
fi
if [ -n "$VERCEL_TOKEN" ]; then
  mkdir -p "$HOME/.local/share/com.vercel.cli"
  printf '{"token":"%s"}\n' "$VERCEL_TOKEN" > "$HOME/.local/share/com.vercel.cli/auth.json"; info "vercel: token"
fi
if [ -n "$HEROKU_API_KEY" ]; then
  git config --global credential.https://git.heroku.com.helper '!heroku git:credentials'; info "heroku: token + git credential helper"
fi
umask 022

# ── 5. lore host access + project checkout ───────────────────────────────────
log "lore + project"
mkdir -p "$HOME/.lore"
[ -f "$HOME/.lore/config.json" ] || printf '{ "remote": "%s" }\n' "$LORE_REMOTE" > "$HOME/.lore/config.json"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "${VM_NAME}-lore-access" -f "$HOME/.ssh/id_ed25519"
fi
LORE_HOST="${LORE_REMOTE#*@}"; LORE_HOST="${LORE_HOST%%:*}"
if ! grep -q "Host $LORE_HOST" "$HOME/.ssh/config" 2>/dev/null; then
  printf 'Host %s\n  StrictHostKeyChecking accept-new\n' "$LORE_HOST" >> "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
fi
if [ -n "$LORE_CONTEXT" ]; then
  CODE="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$LORE_MCP_URL/$LORE_CONTEXT" || true)"
  case "$CODE" in
    000|401|403|404|502|503) warn "lore MCP at $LORE_MCP_URL/$LORE_CONTEXT answered ${CODE}: is the exe.dev 'lore-mcp' integration attached to vm:$VM_NAME? (bootstrap.sh integrations)" ;;
    *) info "lore MCP reachable ($LORE_MCP_URL/$LORE_CONTEXT → HTTP $CODE)" ;;
  esac
  if ! claude mcp get lore >/dev/null 2>&1; then
    claude mcp add --scope user lore -- "$(command -v lore)" mcp --context "$LORE_CONTEXT" >/dev/null
    info "registered MCP server 'lore' (--context $LORE_CONTEXT) for the admin agent"
  fi
fi
if [ -n "$PROJECT_REPO" ]; then
  if [ -d "$PROJECT_DIR/.git" ]; then
    info "project checkout $PROJECT_DIR exists"
  elif git clone -q "https://github.int.exe.xyz/${PROJECT_REPO}.git" "$PROJECT_DIR" 2>/dev/null; then
    info "cloned $PROJECT_REPO → $PROJECT_DIR (via github.int.exe.xyz)"
  else
    warn "could not clone $PROJECT_REPO via github.int.exe.xyz; attach its GitHub integration to vm:$VM_NAME and re-run"
    PROJECT_DIR=""
  fi
fi

# ── 6. enso configuration ────────────────────────────────────────────────────
log "enso configuration"
REPORT="$(mktemp)"; TMPFILES+=("$REPORT")
AGENT_NAME="$AGENT_NAME" VM_NAME="$VM_NAME" ENSO_BIN="$ENSO_BIN" ENSO_HOME="$ENSO_HOME" \
SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_APP_TOKEN="$SLACK_APP_TOKEN" SLACK_OWNER_IDS="$SLACK_OWNER_IDS" \
NOTIFY_CHANNEL="$NOTIFY_CHANNEL" CHANNELS="$CHANNELS" CHANNEL_WORKSPACE="$CHANNEL_WORKSPACE" \
LORE_CONTEXT="$LORE_CONTEXT" LORE_MCP_URL="$LORE_MCP_URL" PROJECT_DIR="$PROJECT_DIR" \
DEFAULT_MODEL="$DEFAULT_MODEL" DEFAULT_EFFORT="$DEFAULT_EFFORT" OPERATOR_NAME="$OPERATOR_NAME" \
WORKSPACE_TEMPLATE="$HERE/templates/AGENTS.workspace.md" REPORT="$REPORT" \
  python3 "$HERE/lib/configure_enso.py"
[ -n "$CHANNEL_WORKSPACE" ] || CHANNEL_WORKSPACE="$(jq -r '[.bindings | to_entries[] | select(.value != "default") | .value][0] // empty' "$ENSO_HOME/config.json")"

# ── 7. House layer ───────────────────────────────────────────────────────────
log "house customizations"
render() {  # render <template> → stdout with placeholders substituted
  sed -e "s|__AGENT_NAME__|${AGENT_NAME}|g" -e "s|__VM_NAME__|${VM_NAME}|g" \
      -e "s|__OPERATOR_NAME__|${OPERATOR_NAME:-the operator}|g" -e "s|__TIMEZONE__|${TIMEZONE:-UTC}|g" \
      -e "s|__SLACK_OWNER_IDS__|${SLACK_OWNER_IDS}|g" "$1"
}
CHANGED=()
AG="$ENSO_HOME/AGENTS.md"
if grep -q "^You're Enso, an assistant" "$AG" && [ "$AGENT_NAME" != Enso ]; then
  sed -i "s/^You're Enso, an assistant/You're ${AGENT_NAME}, an assistant/" "$AG"; CHANGED+=(AGENTS.md)
fi
if ! grep -q "enso-agent-bootstrap:house" "$AG" && ! grep -q "^## This installation" "$AG"; then
  if [ -n "$PROJECT_DIR" ]; then
    PROJECT_SECTION="
## Software development

The project checkout is \`$PROJECT_DIR\` (\`$PROJECT_REPO\`). Follow its \`AGENTS.md\` and branch
workflow. Git access uses \`github.int.exe.xyz\`; use \`gh\` normally through the installed
wrapper, or set \`GH_HOST=github.int.exe.xyz\` explicitly. Never place credentials or real
customer data in the repository.${CHANNEL_WORKSPACE:+ The channels bound to \`$CHANNEL_WORKSPACE\` use one
unrestricted workspace with the full development toolchain, Enso CLI, link access, and Lore.}"
  else PROJECT_SECTION=""; fi
  render "$HERE/templates/AGENTS.house.md" \
    | PS="$PROJECT_SECTION" awk '{ if ($0 == "__PROJECT_SECTION__") { if (ENVIRON["PS"] != "") print ENVIRON["PS"] } else print }' >> "$AG"
  CHANGED+=(AGENTS.md); info "appended the house section to $AG"
fi
DEF="$ENSO_HOME/workspaces/default/AGENTS.md"
if grep -q "^Operate this Enso installation across its workspaces" "$DEF" 2>/dev/null; then
  LINE=""
  [ -n "$CHANNEL_WORKSPACE" ] && LINE="Use the \`$CHANNEL_WORKSPACE\` workspace for project-specific questions and Lore-backed project history. "
  render "$HERE/templates/AGENTS.default.md" | sed "s|__CHANNEL_WORKSPACE_LINE__|${LINE}|" > "$DEF"
  CHANGED+=(workspaces/default/AGENTS.md); info "wrote the operator workspace instructions"
fi
if [ -n "$OPERATOR_NAME" ] && [ ! -e "$ENSO_HOME/shared/knowledge/People/$OPERATOR_NAME.md" ]; then
  render "$HERE/templates/operator.md" | "$ENSO_BIN" knowledge create "People/$OPERATOR_NAME.md" --file - >/dev/null \
    && { CHANGED+=(shared/knowledge); info "knowledge: People/$OPERATOR_NAME.md"; } || warn "could not create the operator knowledge note"
fi
for skill in lore-mcp lore-onboard; do
  if [ ! -d "$ENSO_HOME/skills/$skill" ] && [ -d "$LORE_DIR/plugins/lore/skills/$skill" ]; then
    cp -R "$LORE_DIR/plugins/lore/skills/$skill" "$ENSO_HOME/skills/$skill"; CHANGED+=("skills/$skill"); info "installed skill $skill"
  fi
done
# Migration: the old channel workspace's own knowledge notes come along.
if [ -n "$LEGACY_HOME" ] && [ -n "$CHANNEL_WORKSPACE" ] && [ -d "$LEGACY_HOME/workspaces/$CHANNEL_WORKSPACE/knowledge" ] \
   && [ ! -e "$ENSO_HOME/workspaces/$CHANNEL_WORKSPACE/knowledge" ]; then
  cp -R "$LEGACY_HOME/workspaces/$CHANNEL_WORKSPACE/knowledge" "$ENSO_HOME/workspaces/$CHANNEL_WORKSPACE/knowledge"
  # enso 0.4 notes need its frontmatter; adopt normalizes each without losing content.
  ( cd "$ENSO_HOME/workspaces/$CHANNEL_WORKSPACE/knowledge" && find . -name '*.md' -printf '%P\n' ) | while IFS= read -r note; do
    "$ENSO_BIN" knowledge adopt "$note" --workspace "$CHANNEL_WORKSPACE" >/dev/null 2>&1 || warn "could not adopt knowledge note $note"
  done
  CHANGED+=("workspaces/$CHANNEL_WORKSPACE/knowledge"); info "carried over workspaces/$CHANNEL_WORKSPACE/knowledge"
fi
git -C "$ENSO_HOME" add -A . >/dev/null 2>&1 || true
if ! git -C "$ENSO_HOME" diff --cached --quiet 2>/dev/null; then
  git -C "$ENSO_HOME" commit -q -m "bootstrap: ${LEGACY_HOME:+migrate from $(basename "$LEGACY_HOME"); }house instructions, channel workspace, lore" || true
  info "committed to $ENSO_HOME"
fi

# ── 8. Service ───────────────────────────────────────────────────────────────
log "systemd service"
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
"$ENSO_BIN" service install >/dev/null || die "enso service install failed"
DROPIN_DIR="$HOME/.config/systemd/user/enso.service.d"
rm -f "$DROPIN_DIR/bootstrap.conf"
if grep -q '=' <(grep -v '^#' "$AGENT_ENV"); then
  mkdir -p "$DROPIN_DIR"
  printf '[Service]\nEnvironmentFile=-%s\n' "$AGENT_ENV" > "$DROPIN_DIR/10-agent-env.conf"
else
  rm -f "$DROPIN_DIR/10-agent-env.conf"
fi
systemctl --user daemon-reload
systemctl --user enable enso.service >/dev/null 2>&1 || true
systemctl --user restart enso.service
sleep 6
STATE="$(systemctl --user is-active enso.service || true)"
info "enso.service: $STATE"
[ "$STATE" = "active" ] || { tail -n 20 "$ENSO_HOME/launchd.log" 2>/dev/null | sed 's/^/        /'; die "enso.service is not active"; }
trap - ERR

log "enso config check + doctor"
"$ENSO_BIN" config check 2>&1 | sed 's/^/    /' || warn "config check reported problems (see above)"
"$ENSO_BIN" doctor --attention 2>&1 | sed 's/^/    /' || warn "doctor reported problems (see above)"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
printf '\033[1;32m✅ %s is set up on %s.exe.xyz (enso %s)\033[0m\n' "$AGENT_NAME" "$VM_NAME" "$INSTALLED"
cat <<SUMMARY
   DM the bot in Slack as: $SLACK_OWNER_IDS
   status:  systemctl --user status enso.service   ·   logs: enso logs -f
   config:  $ENSO_HOME/config.json   (bindings; Slack tokens live here, mode 600)
$(cat "$REPORT" 2>/dev/null)
$([ -n "$LEGACY_HOME" ] && printf '   migrated: old home kept at %s, backup %s\n' "$LEGACY_HOME" "$BACKUP")

   Still human, once:
$([ "$CLAUDE_LOGIN_NEEDED" = true ] && printf '   • Claude login — from your laptop: ssh -t %s.exe.xyz claude   (then /login),\n     or put a `claude setup-token` token in CLAUDE_CODE_OAUTH_TOKEN and re-run. Until then Claude cannot answer.\n' "$VM_NAME")
   • lore CLI access for the admin agent — register this VM's key (from your laptop):
       ssh exe.dev ssh-key add --tag=lore "$(cat "$HOME/.ssh/id_ed25519.pub")"
     (bootstrap.sh lore-key <conf> does exactly this; skip if already registered)
   • more channels later: add them to CHANNELS in the conf and re-run install.sh
SUMMARY
