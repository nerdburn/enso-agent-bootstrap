#!/usr/bin/env bash
# Install claude-web (this agent's claude.ai browser session: accepts artifact
# invitations and reads cross-organization artifacts). Idempotent; needs
# lib/playwright.sh first. install.sh runs this; it also runs on its own.
#
# Signing the session in is a person's job (claude.ai asks for a CAPTCHA):
# `./bootstrap.sh web-login <conf>` from the laptop.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$HOME/.local/share/claude-web"
info() { printf '    %s\n' "$*"; }

missing=()
for p in xvfb:Xvfb x11vnc:x11vnc websockify:websockify novnc:/usr/share/novnc/vnc.html; do
  pkg="${p%%:*}"; probe="${p#*:}"
  if [[ "$probe" == /* ]]; then [ -e "$probe" ] || missing+=("$pkg"); else command -v "$probe" >/dev/null || missing+=("$pkg"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
  info "apt install ${missing[*]}"
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
fi

mkdir -p "$BASE" "$HOME/.local/bin"
install -m 644 "$HERE/lib/claude-web.js" "$BASE/claude-web.js"
install -m 755 "$HERE/bin/claude-web" "$HOME/.local/bin/claude-web"
# A profile signed in by hand before this tool existed.
if [ ! -d "$BASE/profile" ] && [ -d "$HOME/.cache/claude-browser/profile" ]; then
  mv "$HOME/.cache/claude-browser/profile" "$BASE/profile"; info "moved the existing browser profile → $BASE/profile"
fi
info "✓ claude-web → $HOME/.local/bin/claude-web"
