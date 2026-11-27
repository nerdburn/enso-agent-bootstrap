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
