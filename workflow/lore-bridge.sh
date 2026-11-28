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
. "$here/common.sh"   # workflow.env plus sync_base, ticket, gist, operator
cmd="${1:?usage: lore-bridge.sh dispatch|transition}"

if [ "$cmd" = dispatch ]; then
  # New tasks start from the local base branch: keep it at origin's.
  sync_base || true
  # Blocks nobody decided, put back automatically:
  #  - a restart of enso cancels in-flight stage runs ("… cancelled (enso stopped)");
  #  - a remote worker's run died on an infrastructure error ("ended (error): enso-worker:
  #    …") while its sandbox may still be working; the next run adopts the sandbox.
  #  - an operator changed the workflow while a run worked ("workflow changed during
  #    execution"): enso refuses that handoff; the next run hands the work off again.
  #  - edited tests that came from the base, not the task (see below).
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
def recent(reason):  # automatic resumes for this same reason in the last 6 hours
    return sum(1 for e in d.get("events") or [] if f"Resumed automatically: {reason}" in str(e.get("message"))
               and dt.datetime.fromisoformat(e["created_at"]) > since)
why = ""
if msg.endswith("(enso stopped)"):
    why = "a restart of enso interrupted its run"
elif "ended (error): enso-worker:" in msg:
    why = "its remote worker hit an infrastructure error"
elif msg.startswith("workflow changed during execution"):
    why = "the workflow was updated while its run was working"
elif msg.startswith("Changed tests or check files need approval"):
    why = "approval"
elif msg.startswith("Verification budget exhausted"):
    why = "budget"
BUDGET = "its attempts went to worker errors or approval gates"
if why == "budget" and recent(BUDGET) >= 3:
    print("stuck|it keeps running out of attempts")
elif why in ("approval", "budget") or not why:
    print(why)
elif why.startswith("the workflow was updated"):
    print(why)  # caused by an operator change, not a fault: never capped
elif recent(why) >= 3:
    print("stuck|" + why)  # the operator hears once; see below
else:
    print(why)')"
    if [[ "$why" == stuck\|* ]]; then
      # Three automatic resumes in six hours did not get it through: tell the operator once.
      mark="$here/state/$ref.stuck"; stamp="$(printf '%s' "$why" | cksum | cut -d' ' -f1)-$(date +%Y%m%d)"
      if [ "$(cat "$mark" 2>/dev/null)" != "$stamp" ]; then
        title="$("$ENSO_BIN" task show "$ref" --workspace "$ENSO_WORKSPACE" --json | python3 -c 'import json, sys; print(json.load(sys.stdin).get("title", ""))')"
        operator "*$(ticket "$title")* is stuck: ${why#stuck|}, 3 times in 6 hours. Look at it, then \`enso task resume $ref\`." && echo "$stamp" > "$mark"
      fi
      why=""
    fi
    if [ "$why" = budget ]; then
      # Out of verification attempts. Attempts spent on worker errors and approval gates
      # are not a failing change: reset and hand off again (counted as an automatic resume).
      # Checks that failed are: the operator hears once.
      why=""
      shown="$("$ENSO_BIN" workflow show "$ref" --workspace "$ENSO_WORKSPACE" 2>/dev/null || true)"
      if grep -qE ': failed \(attempt' <<<"$shown"; then
        mark="$here/state/$ref.budget"; stamp="$(date +%Y%m%d)-$(grep -c . <<<"$shown")"
        if [ "$(cat "$mark" 2>/dev/null)" != "$stamp" ]; then
          title="$("$ENSO_BIN" task show "$ref" --workspace "$ENSO_WORKSPACE" --json | python3 -c 'import json, sys; print(json.load(sys.stdin).get("title", ""))')"
          operator "*$(ticket "$title")* is stuck: its checks keep failing and it is out of attempts. \`enso workflow show $ref\`" && echo "$stamp" > "$mark"
        fi
      elif env -u ENSO_RUN_ID "$ENSO_BIN" workflow retry "$ref" --workspace "$ENSO_WORKSPACE" \
          --message "Attempts went to worker errors or approval gates, not failed checks." >/dev/null 2>&1; then
        why="its attempts went to worker errors or approval gates, not failed checks"
      fi
    fi
    if [ "$why" = approval ]; then
      # Build rebased onto the base itself (resolving conflicts the after:build hook could
      # not), so the base's own test edits look like the task's. `task rebase` moves the
      # trusted start to the base it now contains; then only the task's own edits count.
      # Its own edits, if any, block again on the next handoff and wait for a person.
      why=""
      if env -u ENSO_RUN_ID "$ENSO_BIN" task rebase "$ref" --workspace "$ENSO_WORKSPACE" --json 2>/dev/null \
          | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("changed") else 1)'; then
        why="its branch now contains the latest $WORKFLOW_BASE, so only its own test edits count"
      else
        # The task's own edits: the reviewer approves sound ones and escalates the rest.
        "$here/rules-review.sh" "$ref" || true
      fi
    fi
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
  # Choose the next ticket from Lore's goals (WORKFLOW_PICK=shadow|on; off by default).
  python3 "$here/pick.py" >&2 || true
  # Remote workers: stop sandboxes whose task has moved on (best effort).
  if [ -x "$HOME/.local/bin/enso-worker" ] && [ -s "$HOME/.config/enso-agent/worker-jobs" ]; then
    "$HOME/.local/bin/enso-worker" sweep >&2 || true
  fi
fi
[ "$cmd" = dispatch ] || exec python3 "$here/lore_bridge.py" "$cmd"
# A crash in dispatch repeats every tick: tell the operator once a day per error, in one
# plain sentence (the details stay in the job log), and never fail the job: a failed job
# posts enso's own traceback alert.
err="$(mktemp)"; trap 'rm -f "$err"' EXIT
if python3 "$here/lore_bridge.py" dispatch 2>"$err"; then exit 0; fi
cat "$err" >&2
mkdir -p "$here/state" 2>/dev/null || true
last="$(grep -v '^\s' "$err" | tail -1)"; mark="$here/state/dispatch.error"
stamp="$(date +%Y%m%d)-$(printf '%s' "$last" | cksum | cut -d' ' -f1)"
if [ "$(cat "$mark" 2>/dev/null)" != "$stamp" ]; then
  operator "${WORKFLOW_NAME:-$ENSO_PROJECT}: I can't pick up tickets from Lore right now, so new work is on hold. I'm retrying every 5 minutes and will look into it." \
    && { echo "$stamp" > "$mark" 2>/dev/null || true; }
fi
exit 0
