#!/usr/bin/env bash
# Stage command (publish): push the reviewed candidate and open, or update, its pull
# request against WORKFLOW_BASE. Prints the stage result as JSON; logs go to stderr.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "${ENSO_TASK_DIR:?publish needs the task worktree}"

[ -z "$(git status --porcelain)" ] || result block "The worktree has uncommitted changes; Build must commit everything."
branch="$(git branch --show-current)"
[ -n "$branch" ] || result block "The worktree is not on a branch."
head="$(git rev-parse HEAD)"
git fetch -q origin "$WORKFLOW_BASE" >&2 || true
[ "$(git rev-list --count "origin/$WORKFLOW_BASE..HEAD" 2>/dev/null || echo 1)" != 0 ] \
  || result block "The candidate has no commits on top of $WORKFLOW_BASE."

# --force-with-lease: a revised candidate replaces our own earlier push, but never a commit
# someone else pushed to the branch since.
git push --force-with-lease -u origin "HEAD:refs/heads/$branch" >&2 \
  || result block "Could not push $branch (someone else may have pushed to it); a person should look."

task_json="$("$ENSO_BIN" task show "$ENSO_TASK" --workspace "$ENSO_WORKSPACE" --json)"
title="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["title"])' "$task_json")"
key="$(python3 -c 'import json, sys
refs = json.loads(sys.argv[1]).get("refs") or []
print(next((r["value"] for r in refs if r.get("kind") == "lore"), ""))' "$task_json")"

pr="$(gh pr list -R "$WORKFLOW_REPO" --head "$branch" --state open --json url --jq '.[0].url // empty')"
if [ -z "$pr" ]; then
  body="$(printf '%s\n\n---\n%sOpened by %s from task %s. Merged only after review, QA on the preview and approval of this exact version.\n' \
    "$(stage_output "$ENSO_TASK" review)" "${key:+Lore: $key. }" "$WORKFLOW_AGENT" "$ENSO_TASK")"
  pr="$(gh pr create -R "$WORKFLOW_REPO" --base "$WORKFLOW_BASE" --head "$branch" --title "$title" --body "$body")"
fi
"$ENSO_BIN" task ref "$ENSO_TASK" url "$pr" --workspace "$ENSO_WORKSPACE" >/dev/null 2>&1 || true

mkdir -p "$here/state"
python3 -c 'import json, sys; json.dump({"pr": sys.argv[1], "head": sys.argv[2], "branch": sys.argv[3]}, open(sys.argv[4], "w"))' \
  "$pr" "$head" "$branch" "$here/state/$ENSO_TASK.json"
result advance "Pushed ${head:0:8} to $branch: $pr" "Pull request: $pr
Branch: $branch
Head: $head"
