#!/usr/bin/env bash
# Install bin/agent-reaper and its nightly systemd --user timer. Idempotent.
#
#   lib/agent-reaper.sh
#
# agent-reaper kills processes that Claude runs left behind in enso.service
# (dev servers, watchers, browsers) once they are over two hours old. The timer
# fires at 04:00 VM time (randomized by up to 20 min, caught up after downtime).
# install.sh runs this; it also runs on its own on an already-installed VM.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$HOME/.local/bin/agent-reaper"
UNITS="$HOME/.config/systemd/user"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
info() { printf '    %s\n' "$*"; }

mkdir -p "$HOME/.local/bin" "$UNITS"
install -m 755 "$HERE/bin/agent-reaper" "$BIN"
cat >"$UNITS/agent-reaper.service" <<EOF
[Unit]
Description=Kill processes Claude runs left behind in enso.service

[Service]
Type=oneshot
ExecStart=$BIN
EOF
cat >"$UNITS/agent-reaper.timer" <<'EOF'
[Unit]
Description=Nightly agent-reaper

[Timer]
OnCalendar=*-*-* 04:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now agent-reaper.timer >/dev/null 2>&1
info "✓ agent-reaper → $BIN (nightly, $(systemctl --user show agent-reaper.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo 'timer'))"
