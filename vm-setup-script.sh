#!/bin/bash
# exe.dev first-boot setup script (passed via `ssh exe.dev new --setup-script`).
# Pre-installs everything that needs no secrets — CLIs, enso checkout, lore —
# so that configuring the agent afterwards takes seconds. Runs once as the
# login user. __BOOTSTRAP_REPO__ is substituted by bootstrap.sh new-vm.
set -u
REPO="__BOOTSTRAP_REPO__"
case "$REPO" in __*) REPO="https://github.com/nerdburn/enso-agent-bootstrap" ;; esac
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"; export HOME
cd "$HOME" || exit 1
LOG="$HOME/enso-agent-bootstrap.log"
{
  echo "== $(date -Is) first-boot: enso-agent-bootstrap tools-only install"
  if [ ! -d enso-agent-bootstrap/.git ]; then
    for i in 1 2 3 4 5 6; do git clone -q "$REPO" enso-agent-bootstrap && break; sleep 10; done
  fi
  [ -x enso-agent-bootstrap/install.sh ] && enso-agent-bootstrap/install.sh --tools-only
  echo "== $(date -Is) done (exit $?)"
} >>"$LOG" 2>&1
