# Sourced by the workflow scripts beside it: settings plus small helpers.
# shellcheck shell=bash
here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/workflow.env"

# stage_output REF STAGE: the latest accepted output of STAGE on task REF, or nothing.
stage_output() {
  "$ENSO_BIN" task show "$1" --workspace "$ENSO_WORKSPACE" --json | python3 "$here/stage_output.py" "$2"
}

# state REF FIELD: a field of publish-pr.sh's record for task REF (pr, head, branch).
state() {
  python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except (OSError, ValueError): print("")' "$here/state/$1.json" "$2"
}

# result OUTCOME MESSAGE [OUTPUT]: print a command stage's result and exit.
result() {
  python3 -c 'import json, sys; print(json.dumps({"outcome": sys.argv[1], "message": sys.argv[2], "output": sys.argv[3] or sys.argv[2]}))' "$1" "$2" "${3:-}"
  exit 0
}

# sync_base: bring the local base branch to origin's. enso cuts task worktrees from it and
# PM reads the checkout on it. Best effort; a failure is reported on stderr.
sync_base() {
  [ -n "${WORKFLOW_REPO_DIR:-}" ] || return 0
  if [ "$(git -C "$WORKFLOW_REPO_DIR" branch --show-current)" = "$WORKFLOW_BASE" ]; then
    git -C "$WORKFLOW_REPO_DIR" pull -q --ff-only origin "$WORKFLOW_BASE" >&2
  else
    git -C "$WORKFLOW_REPO_DIR" fetch -q origin "+$WORKFLOW_BASE:$WORKFLOW_BASE" >&2
  fi || { echo "could not update $WORKFLOW_BASE in $WORKFLOW_REPO_DIR from origin" >&2; return 1; }
}
