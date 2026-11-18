#!/usr/bin/env bash
# Install bin/claude-gate and point enso's claude provider at it. Idempotent.
#
#   lib/claude-gate.sh
#
# Caps concurrent `claude -p` runs on the VM (ENSO_MAX_RUNS in the service env,
# default 3); a chat turn that has to wait tells its thread it is queued.
# install.sh runs this after configuring enso; it also runs on its own on an
# already-installed VM (enso picks the new path up on its next turn).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENSO_BIN="${ENSO_BIN:-$HOME/.local/bin/enso}"
GATE="$HOME/.local/bin/claude-gate"
info() { printf '    %s\n' "$*"; }

mkdir -p "$HOME/.local/bin"
install -m 755 "$HERE/bin/claude-gate" "$GATE"
info "✓ claude-gate → $GATE"

have="$("$ENSO_BIN" config show 2>/dev/null | jq -r '.providers.claude.path // empty' 2>/dev/null || true)"
if [ "$have" != "$GATE" ]; then
  # Remember the CLI enso used until now; the gate runs that one.
  real="${have:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
  mkdir -p "$HOME/.config/enso-agent"; echo "$real" > "$HOME/.config/enso-agent/claude-path"
  info "claude-gate runs $real"
  "$ENSO_BIN" config set providers.claude.path "$GATE" >/dev/null
  info "enso providers.claude.path: ${have:-unset} → $GATE"
else
  info "enso providers.claude.path already $GATE"
fi
