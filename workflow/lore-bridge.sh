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
  # Blocks nobody decided, put back automatically:
  #  - a restart of enso cancels in-flight stage runs ("… cancelled (enso stopped)");
  #  - a remote worker's run died on an infrastructure error ("ended (error): enso-worker:
  #    …") while its sandbox may still be working; the next run adopts the sandbox.
  # At most 3 automatic resumes per task in 6 hours, so a persistent fault reaches a person.
  # A resume refused because the block's hooks are still pending is retried next run.
  for ref in $("$ENSO_BIN" task list --project "$ENSO_PROJECT" --workspace "$ENSO_WORKSPACE" --json \
      | python3 -c 'import json, sys
print(" ".join(t["ref"] for t in json.load(sys.stdin) if t.get("stage") == "blocked"))'); do
    why="$("$ENSO_BIN" task show "$ref" --workspace "$ENSO_WORKSPACE" --json | python3 -c 'import json, sys, datetime as dt
d = json.load(sys.stdin); h = d.get("handoff") or {}; msg = str(h.get("message", ""))
if h.get("actor") != "enso" or h.get("to_stage") != "blocked":
    sys.exit(0)
since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=6)
recent = sum(1 for e in d.get("events") or [] if "Resumed automatically" in str(e.get("message"))
             and dt.datetime.fromisoformat(e["created_at"]) > since)
if recent >= 3:
    sys.exit(0)
if msg.endswith("(enso stopped)"):
    print("a restart of enso interrupted its run")
elif "ended (error): enso-worker:" in msg:
    print("its remote worker hit an infrastructure error")')"
    if [ -n "$why" ]; then
      # Not as this dispatch run: enso lets a run move only the task it claimed. The resume
      # is the operator's standing policy above, carried out by dispatch.
      env -u ENSO_RUN_ID "$ENSO_BIN" task resume "$ref" --workspace "$ENSO_WORKSPACE" \
        --message "Resumed automatically: $why." >&2 \
        && echo "$ref: resumed ($why)" >&2 || true
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
