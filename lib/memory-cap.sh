#!/usr/bin/env bash
# Cap enso.service's memory so a runaway run is killed inside enso instead of
# freezing the whole VM (athena-agent, 2026-11-19). Idempotent.
#
#   lib/memory-cap.sh
#
# Writes ~/.config/systemd/user/enso.service.d/20-memory.conf:
#   MemoryHigh  = 75% of RAM   (the kernel throttles and reclaims above this)
#   MemoryMax   = 87.5% of RAM (hard limit: the OOM killer acts inside the cgroup)
#   OOMPolicy=continue         (only the process killed dies, not all of enso)
# leaving the rest for sshd and the system. ENSO_MEMORY_HIGH / ENSO_MEMORY_MAX
# (systemd sizes such as 12G) override the percentages. A daemon-reload applies
# the limits to the running service; no restart.
set -Eeuo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
info() { printf '    %s\n' "$*"; }

total_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
high="${ENSO_MEMORY_HIGH:-$(( total_mb * 3 / 4 ))M}"
max="${ENSO_MEMORY_MAX:-$(( total_mb * 7 / 8 ))M}"
dir="$HOME/.config/systemd/user/enso.service.d"
file="$dir/20-memory.conf"
mkdir -p "$dir"
want="# lib/memory-cap.sh: keep a runaway run from freezing the VM (${total_mb} MB RAM)
[Service]
MemoryHigh=$high
MemoryMax=$max
OOMPolicy=continue"
if [ "$(cat "$file" 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" >"$file"
  systemctl --user daemon-reload
fi
cg="$(systemctl --user show enso.service -p ControlGroup --value 2>/dev/null || true)"
if [ -n "$cg" ] && grep -qE '^[0-9]+$' "/sys/fs/cgroup$cg/memory.max" 2>/dev/null \
   && grep -qE '^[0-9]+$' "/sys/fs/cgroup$cg/memory.high" 2>/dev/null; then
  info "✓ enso memory cap: high $(( $(cat "/sys/fs/cgroup$cg/memory.high") / 1048576 ))M, max $(( $(cat "/sys/fs/cgroup$cg/memory.max") / 1048576 ))M of ${total_mb}M"
else
  info "✓ enso memory cap: high $high, max $max of ${total_mb}M (applies when enso starts)"
fi
