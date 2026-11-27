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
  # enso cuts task worktrees from the local base branch: keep it at origin's (best effort).
  if [ -n "${WORKFLOW_REPO_DIR:-}" ]; then
    if [ "$(git -C "$WORKFLOW_REPO_DIR" branch --show-current)" = "$WORKFLOW_BASE" ]; then
      git -C "$WORKFLOW_REPO_DIR" pull -q --ff-only origin "$WORKFLOW_BASE" >&2 || true
    else
      git -C "$WORKFLOW_REPO_DIR" fetch -q origin "+$WORKFLOW_BASE:$WORKFLOW_BASE" >&2 || true
    fi
  fi
  # A restart of enso cancels in-flight stage runs and blocks their tasks ("run … ended
  # (cancelled): cancelled (enso stopped)"). Nobody decided anything, so put them back.
  # A resume refused because the block's hooks are still pending is retried next run.
  for ref in $("$ENSO_BIN" task list --project "$ENSO_PROJECT" --workspace "$ENSO_WORKSPACE" --json \
      | python3 -c 'import json, sys
print(" ".join(t["ref"] for t in json.load(sys.stdin) if t.get("stage") == "blocked"))'); do
    if "$ENSO_BIN" task show "$ref" --workspace "$ENSO_WORKSPACE" --json | python3 -c 'import json, sys
h = json.load(sys.stdin).get("handoff") or {}
sys.exit(0 if h.get("actor") == "enso" and h.get("to_stage") == "blocked"
         and str(h.get("message", "")).endswith("(enso stopped)") else 1)'; then
      "$ENSO_BIN" task resume "$ref" --workspace "$ENSO_WORKSPACE" \
        --message "Resumed automatically: a restart of enso interrupted its run." >&2 \
        && echo "$ref: resumed after an enso restart" >&2 || true
    fi
  done
  active="$("$ENSO_BIN" task list --project "$ENSO_PROJECT" --workspace "$ENSO_WORKSPACE" --json \
    | python3 -c 'import json, sys
tasks = json.load(sys.stdin)
print(sum(1 for t in tasks if t.get("stage") not in ("backlog", "blocked", "done", "cancelled")))')"
  room=$(( WORKFLOW_WIP_LIMIT - active ))
  (( room < 0 )) && room=0
  (( room < LORE_MAX_NEW )) && LORE_MAX_NEW=$room
  export LORE_MAX_NEW
  # Remote workers: stop sandboxes whose task has moved on (best effort).
  if [ -x "$HOME/.local/bin/enso-worker" ] && [ -s "$HOME/.config/enso-agent/worker-jobs" ]; then
    "$HOME/.local/bin/enso-worker" sweep >&2 || true
  fi
fi
exec python3 "$here/lore_bridge.py" "$cmd"
