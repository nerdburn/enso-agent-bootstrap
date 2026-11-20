#!/usr/bin/env bash
# code-pause.sh (runs on YOUR LAPTOP): pause or resume code changes per agent.
#
#   ./code-pause.sh <agent|all> status
#   ./code-pause.sh <agent>... on ["note"]     e.g. ./code-pause.sh athena on "until the release"
#   ./code-pause.sh <agent>... off
#
# <agent> is the VM name with or without "-agent" (athena, athena-agent); several can be
# given before the action, and "all" means every exe.dev VM tagged #enso-agent.
# While paused the agent keeps reading code, reviewing PRs, planning and making
# artifacts, but a Claude Code hook blocks edits in code repositories, commits, pushes,
# merges and PR changes, and its AGENTS.md says why (bin/no-code-guard,
# bin/agent-code-pause). Takes effect on the agent's next tool call; no restart.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

agents=()
while [ $# -gt 0 ]; do
  case "$1" in on|off|status) break ;; -h|--help) usage ;; *) agents+=("$1"); shift ;; esac
done
action="${1:-}"; note="${2:-}"
[ ${#agents[@]} -gt 0 ] && [ -n "$action" ] || usage

if [ "${agents[*]}" = all ]; then
  agents=()
  while IFS= read -r vm; do agents+=("$vm"); done < <(ssh -o BatchMode=yes exe.dev ls 2>/dev/null \
    | sed -n 's/^  • \([^ ]*\)\.exe\.xyz .*#enso-agent.*/\1/p')
  [ ${#agents[@]} -gt 0 ] || { echo "no #enso-agent VMs found (ssh exe.dev ls)" >&2; exit 1; }
fi

rc=0
for a in "${agents[@]}"; do
  vm="${a%.exe.xyz}"; case "$vm" in *-agent) ;; *) vm="$vm-agent" ;; esac
  # Ship the current guard and switch each time, so a VM installed before them works.
  out="$(tar -C "$HERE" -cf - bin/no-code-guard bin/agent-code-pause lib/code-pause.sh 2>/dev/null \
    | ssh -o ConnectTimeout=15 -o BatchMode=yes "$vm.exe.xyz" \
        "d=\$(mktemp -d) && tar -xf - -C \"\$d\" 2>/dev/null && bash \"\$d/lib/code-pause.sh\" >/dev/null \
         && ~/.local/bin/agent-code-pause $action $(printf '%q' "$note"); s=\$?; rm -r -- \"\$d\"; exit \$s" 2>&1)" || rc=1
  printf '%-16s %s\n' "${vm%-agent}" "$out"
done
exit $rc
