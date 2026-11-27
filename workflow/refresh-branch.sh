#!/usr/bin/env bash
# Lifecycle hook (after:build): before Build picks a task up, whether it is new, answered
# after a question, or sent back by review, QA or the approver, move its branch onto the
# latest base so it never builds on a stale copy. `enso task rebase` also moves the task's
# trusted start, so the edited-tests check still sees only the task's own changes.
#
# Best effort: a hook that failed would hold the task. A conflict leaves the branch as it
# is, and the note asks Build to rebase and resolve it; dispatch then clears the base's
# test edits from the approval gate (lore-bridge.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sync_base || true
# Dispatch's automatic resume after an interrupted run: its sandbox may still be working on
# this branch, and the next run adopts it. Moving the branch now would discard that turn.
[[ "${ENSO_MESSAGE:-}" == "Resumed automatically:"* ]] && exit 0
if ! out="$(env -u ENSO_RUN_ID "$ENSO_BIN" task rebase "$ENSO_TASK" --workspace "$ENSO_WORKSPACE" 2>&1)"; then
  case "$out" in
    *"no worktree yet"*) exit 0 ;;  # a new task: its worktree is cut from the fresh base
  esac
  echo "refresh-branch.sh: $out" >&2
  case "$out" in
    *conflicts*)
      env -u ENSO_RUN_ID "$ENSO_BIN" task note "$ENSO_TASK" --workspace "$ENSO_WORKSPACE" \
        "Could not move this branch onto the latest $WORKFLOW_BASE: conflicts in ${out#*conflicts: }. Rebase onto origin/$WORKFLOW_BASE yourself and resolve them before handing off; the test edits that come from $WORKFLOW_BASE are cleared automatically." >/dev/null 2>&1 || true ;;
  esac
fi
echo "$out"
exit 0
