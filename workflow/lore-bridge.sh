#!/usr/bin/env bash
# Run lore's enso bridge (lore_bridge.py, fetched beside this script at a pinned commit)
# with this project's settings.
#
#   ./lore-bridge.sh dispatch     the <prefix>-lore-dispatch job: heartbeat, admit, reconcile
#   ./lore-bridge.sh transition   PROJECT.md after_transition hook
#
# dispatch admits new tickets only while fewer than WORKFLOW_WIP_LIMIT tasks are active.
# Blocked tasks (waiting on a person) and backlog do not count, so unanswered questions do
# not hold capacity.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/workflow.env"
cmd="${1:?usage: lore-bridge.sh dispatch|transition}"

if [ "$cmd" = dispatch ]; then
  active="$("$ENSO_BIN" task list --project "$ENSO_PROJECT" --workspace "$ENSO_WORKSPACE" --json \
    | python3 -c 'import json, sys
tasks = json.load(sys.stdin)
print(sum(1 for t in tasks if t.get("stage") not in ("backlog", "blocked", "done", "cancelled")))')"
  room=$(( WORKFLOW_WIP_LIMIT - active ))
  (( room < 0 )) && room=0
  (( room < LORE_MAX_NEW )) && LORE_MAX_NEW=$room
  export LORE_MAX_NEW
fi
exec python3 "$here/lore_bridge.py" "$cmd"
