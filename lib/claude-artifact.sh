#!/usr/bin/env bash
# Install bin/claude-artifact (claude.ai artifact links → page content). Idempotent.
#
#   lib/claude-artifact.sh                    # tmux + ~/.local/bin/claude-artifact
#   lib/claude-artifact.sh --note <AGENTS.md> # also append the how-to section, once
#
# `claude -p` (how enso runs Claude) has no Artifact tool; the command gets it
# from a throwaway interactive session in tmux. install.sh runs this; it also
# runs on its own on an already-installed VM.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTE=""
[ "${1:-}" = --note ] && NOTE="${2:?--note needs the AGENTS.md path}"
info() { printf '    %s\n' "$*"; }

command -v tmux >/dev/null 2>&1 || { info "apt install tmux"; sudo apt-get install -y -qq tmux >/dev/null; }
mkdir -p "$HOME/.local/bin"
install -m 755 "$HERE/bin/claude-artifact" "$HOME/.local/bin/claude-artifact"
info "✓ claude-artifact → $HOME/.local/bin/claude-artifact"

# The section runs from its marker to the next bootstrap marker, "## " heading
# or the end of the file. It is removed and appended fresh, so the file only
# changes when the template did (or the section was not last yet).
if [ -n "$NOTE" ] && [ -f "$NOTE" ]; then
  before="$(cksum <"$NOTE")"
  perl -0pi -e 's/\n*<!-- enso-agent-bootstrap:claude-artifact -->\n.*?(?=\n<!-- enso-agent-bootstrap:|\n## (?!claude\.ai artifact links)|\z)/\n/s' "$NOTE"
  { echo; cat "$HERE/templates/AGENTS.claude-artifact.md"; } >> "$NOTE"
  if [ "$(cksum <"$NOTE")" != "$before" ]; then
    info "claude-artifact section → $NOTE"
    home="$(dirname "$NOTE")"
    if git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$home" add AGENTS.md && git -C "$home" commit -q -m "bootstrap: claude-artifact" -- AGENTS.md || true
    fi
  fi
fi
