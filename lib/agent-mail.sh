#!/usr/bin/env bash
# Install bin/agent-mail (this agent's own email, through the mail broker). Idempotent.
#
#   lib/agent-mail.sh                       # ~/.local/bin/agent-mail
#   lib/agent-mail.sh --note <AGENTS.md>    # also add/refresh the how-to section
#   lib/agent-mail.sh --no-note <AGENTS.md> # remove the section (no key on this VM)
#
# install.sh runs this; it also runs on its own on an already-installed VM.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""; NOTE=""
case "${1:-}" in --note|--no-note) MODE="$1"; NOTE="${2:?$1 needs the AGENTS.md path}" ;; esac
info() { printf '    %s\n' "$*"; }

mkdir -p "$HOME/.local/bin"
install -m 755 "$HERE/bin/agent-mail" "$HOME/.local/bin/agent-mail"
info "✓ agent-mail → $HOME/.local/bin/agent-mail"

[ -n "$NOTE" ] && [ -f "$NOTE" ] || exit 0
before="$(cksum <"$NOTE")"
# The section runs from its marker to the next bootstrap marker, "## " heading or EOF.
perl -0pi -e 's/\n*<!-- enso-agent-bootstrap:agent-mail -->\n.*?(?=\n<!-- enso-agent-bootstrap:|\n## (?!Email)|\z)/\n/s' "$NOTE"
[ "$MODE" = --note ] && { echo; cat "$HERE/templates/AGENTS.agent-mail.md"; } >> "$NOTE"
if [ "$(cksum <"$NOTE")" != "$before" ]; then
  info "agent-mail section $([ "$MODE" = --note ] && echo '→' || echo 'removed from') $NOTE"
  home="$(dirname "$NOTE")"
  if git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$home" add AGENTS.md && git -C "$home" commit -q -m "bootstrap: agent-mail" -- AGENTS.md || true
  fi
fi
