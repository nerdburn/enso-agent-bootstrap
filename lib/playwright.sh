#!/usr/bin/env bash
# Headless Chromium for the agent, through Playwright. Idempotent.
#
#   lib/playwright.sh                    # install Playwright + Chromium (+ its apt deps)
#   lib/playwright.sh --note <AGENTS.md> # also append the browser section, once
#
# install.sh runs both; the script also runs on its own on an already-installed
# VM (an older bootstrap checkout or enso home), which is how existing agents get it.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTE=""
[ "${1:-}" = --note ] && NOTE="${2:?--note needs the AGENTS.md path}"
info() { printf '    %s\n' "$*"; }
export PATH="$HOME/.local/bin:$PATH"

if ! command -v playwright >/dev/null 2>&1; then
  info "npm install -g playwright"
  sudo npm install -g --no-fund --no-audit playwright >/dev/null
fi
# install-deps runs apt, so only on the first install; `install chromium` is a
# no-op when the browser for this Playwright version is already downloaded.
if ! ls -d "$HOME"/.cache/ms-playwright/chromium_headless_shell-* >/dev/null 2>&1; then
  info "playwright: Chromium system packages"
  sudo env PATH="$PATH" playwright install-deps chromium >/dev/null 2>&1
fi
playwright install chromium >/dev/null
# The global node_modules that holds playwright. Not `npm root -g`: a VM whose
# user npm prefix is ~/node or ~/.npm-global still gets it under sudo's prefix.
PW_NODE_PATH="$(dirname "$(dirname "$(readlink -f "$(command -v playwright)")")")"
[ -d "$PW_NODE_PATH/playwright" ] || { echo "playwright: cannot locate its node_modules" >&2; exit 1; }
NODE_PATH="$PW_NODE_PATH" node -e '
  require("playwright").chromium.launch().then(b => b.close())
    .catch(e => { console.error(e.message); process.exit(1); })' \
  || { echo "playwright: headless Chromium failed to launch" >&2; exit 1; }
info "✓ playwright $(playwright --version | awk '{print $2}') + headless Chromium"

if [ -n "$NOTE" ] && [ -f "$NOTE" ] && ! grep -q "enso-agent-bootstrap:browser" "$NOTE"; then
  { echo; sed "s|__PLAYWRIGHT_NODE_PATH__|$PW_NODE_PATH|g" "$HERE/templates/AGENTS.browser.md"; } >> "$NOTE"
  info "added the browser section to $NOTE"
  home="$(dirname "$NOTE")"
  if git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$home" add AGENTS.md && git -C "$home" commit -q -m "bootstrap: headless browser (Playwright)" -- AGENTS.md || true
  fi
fi
