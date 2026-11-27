#!/usr/bin/env bash
# Install the development workflow for the agent's project: an enso project whose tasks
# come from Lore tickets (lore's enso bridge), with stage jobs and Slack notices. Idempotent.
#
#   lib/workflow.sh <conf>
#
# Does nothing unless the conf sets WORKFLOW_PROJECT. Renders workflow/ into the channel
# workspace (lib/configure_workflow.py), clones WORKFLOW_REPO to ~/apps, fetches
# lore_bridge.py at LORE_BRIDGE_REF, and validates with `enso config check`.
#
# Nothing starts on its own: a fresh install leaves the project and every job disabled, and
# a re-run keeps whatever is enabled. Turn things on with
#   enso workflow enable <KEY>            (required before any task can be created)
#   enso job enable <ws>:<prefix>-<stage> (each stage that should run by itself)
#   enso job enable <ws>:<prefix>-lore-dispatch
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${1:?usage: lib/workflow.sh <conf>}"
info() { printf '    %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

# shellcheck source=/dev/null
. "$CONF"
[ -n "${WORKFLOW_PROJECT:-}" ] || { info "no WORKFLOW_PROJECT in the conf; development workflow skipped"; exit 0; }

export ENSO_HOME="${ENSO_HOME:-$HOME/.enso}"
export ENSO_BIN="${ENSO_BIN:-$HOME/.local/bin/enso}"
: "${WORKFLOW_REPO:?WORKFLOW_REPO (owner/repo) is required}"
: "${WORKFLOW_CHANNEL:?WORKFLOW_CHANNEL (the C… channel for questions and signoff) is required}"
: "${WORKFLOW_APPROVERS:?WORKFLOW_APPROVERS (Slack member IDs) is required}"
: "${LORE_CONTEXT:?LORE_CONTEXT is required}"

repo_name="${WORKFLOW_REPO##*/}"
export WORKFLOW_REPO_DIR="${WORKFLOW_REPO_DIR:-$HOME/apps/$repo_name}"
if [ ! -d "$WORKFLOW_REPO_DIR/.git" ]; then
  info "cloning $WORKFLOW_REPO → $WORKFLOW_REPO_DIR"
  mkdir -p "$(dirname "$WORKFLOW_REPO_DIR")"
  git clone -q "https://github.com/$WORKFLOW_REPO.git" "$WORKFLOW_REPO_DIR"
fi
export WORKFLOW_BASE="${WORKFLOW_BASE:-$(git -C "$WORKFLOW_REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)}"
# enso cuts task worktrees from the LOCAL base branch, so it must exist and track origin
# (lore-bridge.sh dispatch keeps it current). Nothing commits to it locally.
if [ "$(git -C "$WORKFLOW_REPO_DIR" branch --show-current)" = "$WORKFLOW_BASE" ]; then
  git -C "$WORKFLOW_REPO_DIR" pull -q --ff-only origin "$WORKFLOW_BASE" || warn "could not update $WORKFLOW_BASE in $WORKFLOW_REPO_DIR"
else
  git -C "$WORKFLOW_REPO_DIR" fetch -q origin "+$WORKFLOW_BASE:$WORKFLOW_BASE" || warn "could not fetch $WORKFLOW_BASE in $WORKFLOW_REPO_DIR"
fi

export CHANNEL_WORKSPACE AGENT_NAME WORKFLOW_PROJECT WORKFLOW_REPO WORKFLOW_CHANNEL WORKFLOW_APPROVERS
export WORKFLOW_NAME="${WORKFLOW_NAME:-}" WORKFLOW_APPROVER_LABEL="${WORKFLOW_APPROVER_LABEL:-}"
export WORKFLOW_SETUP="${WORKFLOW_SETUP:-npm ci}"
export WORKFLOW_CHECKS="${WORKFLOW_CHECKS:-lint: npm run lint
tests: npm test}"
export WORKFLOW_AGENT_SPEC="${WORKFLOW_AGENT:-claude/${DEFAULT_MODEL:-opus}/${DEFAULT_EFFORT:-high}}"
export WORKFLOW_REVIEW_AGENT="${WORKFLOW_REVIEW_AGENT:-$WORKFLOW_AGENT_SPEC}"
export WORKFLOW_MAX_CONCURRENCY="${WORKFLOW_MAX_CONCURRENCY:-2}" WORKFLOW_WIP_LIMIT="${WORKFLOW_WIP_LIMIT:-3}"
export WORKFLOW_CI_WAIT="${WORKFLOW_CI_WAIT:-2700}" WORKFLOW_CHECK_TIMEOUT="${WORKFLOW_CHECK_TIMEOUT:-1200}"
export WORKFLOW_DISPATCH_SCHEDULE="${WORKFLOW_DISPATCH_SCHEDULE:-*/5 * * * *}"
export LORE_PROJECT="${LORE_PROJECT:-${LORE_CONTEXT#lore-}}"
export LORE_ASSIGNEE="${LORE_ASSIGNEE:-$AGENT_NAME}"
export LORE_HOLDER="${LORE_HOLDER:-enso:$(tr '[:upper:]' '[:lower:]' <<<"$AGENT_NAME")}"
export LORE_MAX_NEW="${LORE_MAX_NEW:-1}"
export WORKER_JOBS="${WORKER_JOBS:-}"   # stage jobs run by enso-worker (lib/worker.sh)
export WORKER_PARALLEL="${WORKER_PARALLEL:-1}" WORKER_JOB_TIMEOUT="${WORKER_JOB_TIMEOUT:-10800}"

python3 "$HERE/lib/configure_workflow.py"

# lore's bridge, pinned: the claim/unique-ref protocol has to match the installed lore.
LORE_BRIDGE_REF="${LORE_BRIDGE_REF:-b91d02f}"
project_dir="$ENSO_HOME/workspaces/$CHANNEL_WORKSPACE/projects/$WORKFLOW_PROJECT"
bridge="$project_dir/lore_bridge.py"
if [ ! -f "$bridge" ] || ! grep -q "lore-bridge-ref: $LORE_BRIDGE_REF" "$bridge"; then
  tmp="$(mktemp)"
  if gh api -H 'Accept: application/vnd.github.raw' \
       "repos/nerdburn/lore/contents/integrations/enso/lore_bridge.py?ref=$LORE_BRIDGE_REF" >"$tmp" 2>/dev/null \
     && grep -q 'def dispatch' "$tmp"; then
    { cat "$tmp"; echo "# lore-bridge-ref: $LORE_BRIDGE_REF"; } >"$bridge"
    chmod 600 "$bridge"
    info "lore_bridge.py @ $LORE_BRIDGE_REF → $bridge"
  else
    warn "could not fetch lore_bridge.py at $LORE_BRIDGE_REF; Lore dispatch will not work until it is in $bridge"
  fi
  rm -f "$tmp"
fi

if ! "$ENSO_BIN" config check >/dev/null 2>&1; then
  "$ENSO_BIN" config check >&2 || true
  warn "enso config check failed after rendering $WORKFLOW_PROJECT; see above"
  exit 1
fi
info "✓ $WORKFLOW_PROJECT workflow rendered and validated"
