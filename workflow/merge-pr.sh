#!/usr/bin/env bash
# Stage command (merge): merge the task's pull request once CI has passed on the version
# that was reviewed (and, on the full route, approved). Prints the stage result as JSON.
#
# The repository's CI decides: every check run and commit status on the PR head must have
# finished, none failed, and at least one check run exists. Waits up to WORKFLOW_CI_WAIT
# seconds for CI that is still running. The PR head must still be the commit publish
# pushed; anything else (someone pushed to the branch) blocks for a person.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "${ENSO_TASK_DIR:?merge needs the task worktree}"

pr="$(state "$ENSO_TASK" pr)"; approved="$(state "$ENSO_TASK" head)"
[ -n "$pr" ] || result block "No pull request is recorded for $ENSO_TASK; publish has not run."
candidate="$(git rev-parse HEAD)"
[ "$candidate" = "$approved" ] \
  || result block "The worktree is at ${candidate:0:8} but ${approved:0:8} was published; publish again before merging."

view() { gh pr view "$pr" -R "$WORKFLOW_REPO" --json "$1" --jq "$2"; }
[ "$(view state .state)" = OPEN ] || result block "$pr is not open ($(view state .state))."
remote_head="$(view headRefOid .headRefOid)"
[ "$remote_head" = "$approved" ] \
  || result block "$pr head is ${remote_head:0:8}, not the approved ${approved:0:8}: someone pushed to the branch. A person should look; the change needs review and approval again."

# CI on the approved head.
deadline=$(( SECONDS + WORKFLOW_CI_WAIT ))
while :; do
  ci="$(gh api "repos/$WORKFLOW_REPO/commits/$approved/check-runs?per_page=100" --jq '
    [.check_runs[] | {name, status, conclusion}]' )"
  statuses="$(gh api "repos/$WORKFLOW_REPO/commits/$approved/status" --jq '[.statuses[] | {context, state}]')"
  verdict="$(python3 - "$ci" "$statuses" <<'PY'
import json, sys
runs, statuses = json.loads(sys.argv[1]), json.loads(sys.argv[2])
failed = [r["name"] for r in runs if r["status"] == "completed" and r["conclusion"] not in ("success", "neutral", "skipped")]
failed += [s["context"] for s in statuses if s["state"] in ("failure", "error")]
pending = [r["name"] for r in runs if r["status"] != "completed"] + [s["context"] for s in statuses if s["state"] == "pending"]
if failed:
    print("failed " + ", ".join(sorted(set(failed))))
elif pending or not runs:
    print("pending " + (", ".join(sorted(set(pending))) or "no check runs yet"))
else:
    print("passed")
PY
)"
  case "$verdict" in
    passed) break ;;
    failed*) result return "CI failed on ${approved:0:8}: ${verdict#failed }. Fix it in Build; see $pr." ;;
    pending*) (( SECONDS < deadline )) || result block "CI still running on ${approved:0:8} after $(( WORKFLOW_CI_WAIT / 60 )) minutes (${verdict#pending }). Resume the task to wait again."
              sleep 30 ;;
  esac
done

case "$(view mergeable .mergeable)" in
  CONFLICTING) result return "$pr conflicts with $WORKFLOW_BASE. Rebase onto $WORKFLOW_BASE in Build and resolve; the change then needs review and approval again." ;;
esac

gh pr ready "$pr" -R "$WORKFLOW_REPO" >/dev/null 2>&1 || true
gh pr merge "$pr" -R "$WORKFLOW_REPO" --merge --match-head-commit "$approved" >&2 \
  || result block "GitHub refused to merge $pr at ${approved:0:8}; a person should look."
merged="$(view mergeCommit .mergeCommit.oid)"
"$ENSO_BIN" task ref "$ENSO_TASK" commit "$merged" --workspace "$ENSO_WORKSPACE" >/dev/null 2>&1 || true
result advance "Merged $pr into $WORKFLOW_BASE as ${merged:0:8}." "Merged $pr
Merge commit: $merged
Approved head: $approved"
