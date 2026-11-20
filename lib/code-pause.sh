#!/usr/bin/env bash
# Install the code-pause switch: bin/no-code-guard as a Claude Code PreToolUse hook in
# ~/.claude/settings.json, and bin/agent-code-pause to flip it. Idempotent.
#
#   lib/code-pause.sh
#
# The hook is always registered but does nothing until `agent-code-pause on` (or
# ./code-pause.sh <agent> on from the laptop) creates its flag. Installing never
# changes whether the VM is paused.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$HOME/.local/bin/no-code-guard"
SETTINGS="$HOME/.claude/settings.json"
info() { printf '    %s\n' "$*"; }

mkdir -p "$HOME/.local/bin" "$HOME/.claude"
install -m 755 "$HERE/bin/no-code-guard" "$GUARD"
install -m 755 "$HERE/bin/agent-code-pause" "$HOME/.local/bin/agent-code-pause"
[ -s "$SETTINGS" ] || echo '{}' >"$SETTINGS"
tmp="$(mktemp)"
jq --arg g "$GUARD" '
  .hooks.PreToolUse = (
    ((.hooks.PreToolUse // []) | map(select(([.hooks[]?.command] | index($g)) | not)))
    + [{matcher: "Edit|Write|MultiEdit|NotebookEdit|Bash",
        hooks: [{type: "command", command: $g, timeout: 20}]}])' "$SETTINGS" >"$tmp"
if [ -s "$tmp" ] && ! cmp -s "$tmp" "$SETTINGS"; then
  cat "$tmp" >"$SETTINGS"
  info "✓ no-code-guard hook → $SETTINGS"
fi
rm -f "$tmp"
info "✓ code-pause: $("$HOME/.local/bin/agent-code-pause" status 2>/dev/null)"
