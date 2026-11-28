#!/usr/bin/env bash
# Remote workers: run the listed enso stage jobs in Vercel Sandboxes. Idempotent.
#
#   lib/worker.sh <conf>
#
# Does nothing unless the conf sets WORKER_JOBS. Installs bin/enso-worker, writes
# ~/.config/enso-agent/worker.env (Vercel team/project and sizing; the Claude
# token is kept from the existing file unless the conf sets CLAUDE_WORKER_TOKEN)
# and ~/.config/enso-agent/worker-jobs, which claude-gate reads on every run.
# Store the token with bin/worker-token on the VM; it never needs to be in the conf.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${1:?usage: lib/worker.sh <conf>}"
info() { printf '    %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
# shellcheck source=/dev/null
. "$CONF"
[ -n "${WORKER_JOBS:-}" ] || { info "no WORKER_JOBS in the conf; remote workers skipped"; exit 0; }
: "${WORKER_SCOPE:?WORKER_SCOPE (Vercel team) is required}"
: "${WORKER_PROJECT:?WORKER_PROJECT (Vercel project for sandboxes) is required}"

DIR="$HOME/.config/enso-agent"; ENVF="$DIR/worker.env"
mkdir -p "$DIR" "$HOME/.local/bin"
install -m 755 "$HERE/bin/enso-worker" "$HOME/.local/bin/enso-worker"
install -m 755 "$HERE/bin/worker-token" "$HOME/.local/bin/worker-token"

kept() { [ -f "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | tail -1 || true; }
token="${CLAUDE_WORKER_TOKEN:-$(kept CLAUDE_WORKER_TOKEN)}"
vtoken="${VERCEL_AUTH_TOKEN:-$(kept VERCEL_AUTH_TOKEN)}"
umask 077
{
  echo "# Written by enso-agent-bootstrap (lib/worker.sh). bin/worker-token sets the tokens."
  echo "WORKER_SCOPE=$WORKER_SCOPE"
  echo "WORKER_PROJECT=$WORKER_PROJECT"
  echo "WORKER_VCPUS=${WORKER_VCPUS:-4}"
  echo "WORKER_TIMEOUT=${WORKER_TIMEOUT:-4h}"
  echo "WORKER_MAX=${WORKER_MAX:-5}"
  echo "WORKER_SETUP=${WORKER_SETUP:-npm ci --no-audit --no-fund}"
  if [ -n "$token" ]; then echo "CLAUDE_WORKER_TOKEN=$token"; fi
  if [ -n "$vtoken" ]; then echo "VERCEL_AUTH_TOKEN=$vtoken"; fi
} > "$ENVF.tmp"
mv "$ENVF.tmp" "$ENVF"
# Merge: several projects on one VM each install their own remote jobs.
{ cat "$DIR/worker-jobs" 2>/dev/null || true; tr ' ' '\n' <<<"$WORKER_JOBS"; } | sed '/^$/d' | sort -u > "$DIR/worker-jobs.tmp"
mv "$DIR/worker-jobs.tmp" "$DIR/worker-jobs"
info "✓ enso-worker: $(tr '\n' ' ' < "$DIR/worker-jobs")→ Vercel $WORKER_SCOPE/$WORKER_PROJECT"

[ -n "$token" ] || warn "no Claude token for workers yet: ssh -t <vm>.exe.xyz ~/.local/bin/worker-token claude"
if ! VERCEL_AUTH_TOKEN="$vtoken" timeout 60 vercel sandbox list --scope "$WORKER_SCOPE" --project "$WORKER_PROJECT" </dev/null >/dev/null 2>&1; then
  warn "vercel sandbox cannot reach $WORKER_SCOPE/$WORKER_PROJECT from this VM: ssh -t <vm>.exe.xyz ~/.local/bin/worker-token vercel"
fi
exit 0
