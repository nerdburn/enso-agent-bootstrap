#!/usr/bin/env bash
# Run enso's web viewer (runs, jobs, threads) at https://<vm>.exe.xyz/. Idempotent.
#
#   ENSO_BIN=~/.local/bin/enso ENSO_HOME=~/.enso lib/enso-web.sh
#
# exe.dev's HTTPS proxy forwards https://<vm>.exe.xyz/ to port 8000 on the VM, so
# the viewer listens on 0.0.0.0:8000 (web.host / web.port / web.hosts in config.json)
# as the systemd --user unit enso-web.service (`enso web install`). The viewer has no
# login of its own: the VM's exe.dev share stays Private, so only people with exe.dev
# access to the VM can open it (`ssh exe.dev share add <vm> <email>` to add someone).
# Each VM's network is isolated, so 0.0.0.0 is not reachable from other VMs.
# If something else already listens on 8000, the viewer is skipped with a warning.
set -Eeuo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ENSO_BIN="${ENSO_BIN:-$HOME/.local/bin/enso}"
export ENSO_HOME="${ENSO_HOME:-$HOME/.enso}"
PORT=8000
HOST_NAME="$(hostname -s).exe.xyz"
info() { printf '    %s\n' "$*"; }

if ss -ltn 2>/dev/null | grep -q ":$PORT " && ! systemctl --user is-active -q enso-web.service; then
  info "! enso web viewer skipped: port $PORT is in use ($(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -o 'users:(("[^"]*' | cut -d'"' -f2))"
  exit 0
fi

want="$(jq -c --arg h "$HOST_NAME" --argjson p "$PORT" '.web == {host: "0.0.0.0", port: $p, hosts: [$h]}' "$ENSO_HOME/config.json")"
if [ "$want" != true ]; then
  "$ENSO_BIN" config set web.host 0.0.0.0 >/dev/null
  "$ENSO_BIN" config set web.port "$PORT" >/dev/null
  "$ENSO_BIN" config set web.hosts "[\"$HOST_NAME\"]" >/dev/null
  changed=1
fi
if [ ! -f "$HOME/.config/systemd/user/enso-web.service" ]; then
  "$ENSO_BIN" web install >/dev/null 2>&1
elif [ -n "${changed:-}" ] || ! systemctl --user is-active -q enso-web.service; then
  systemctl --user restart enso-web.service
fi

for _ in 1 2 3 4 5; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST_NAME" "http://127.0.0.1:$PORT/today" || true)"
  [ "$code" = 200 ] && break; sleep 1
done
if [ "$code" = 200 ]; then
  info "✓ enso web viewer → https://$HOST_NAME/ (exe.dev login)"
else
  info "! enso web viewer not answering on :$PORT (HTTP $code); see journalctl --user -u enso-web"
  exit 1
fi
