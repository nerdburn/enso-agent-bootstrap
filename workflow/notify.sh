#!/usr/bin/env bash
# Lifecycle hook (after:blocked, after:signoff): tell the right person a task needs them.
#
#   question from pm/build/qa  → the client channel, mentioning the approvers; they answer
#                                in the thread and the agent resumes the task
#   ready for signoff          → the client channel: summary, PR, preview, "approve?"
#   failure / approval of edited tests / a block from publish or merge
#                              → the operator (the transport's notify target)
#   a person's own stop or block (no stage run) → nothing
#
# Best effort: a failed hook would hold the task until retried, so a lost notice only logs.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ref="$ENSO_TASK"
title="${ENSO_TASK_TITLE:-$ref}"
message="${ENSO_MESSAGE:-}"
mentions="$(for u in $WORKFLOW_APPROVERS; do printf '<@%s> ' "$u"; done)"

send() {  # send TARGET (empty: the operator) < text
  local args=(message send -)
  [ -n "$1" ] && args+=(--to "slack:$1")
  "$ENSO_BIN" "${args[@]}" --workspace "$ENSO_WORKSPACE" >/dev/null \
    || echo "notify.sh: not sent to ${1:-operator}: $ref" >&2
}

# A block made outside a stage run (no ENSO_RUN_ID) is a person's, or the agent acting on
# a person's word in chat (pause, defer, handoff): that thread already has the answer.
[ "$ENSO_TO_STAGE" = blocked ] && [ -z "${ENSO_RUN_ID:-}" ] && exit 0
# A run cancelled by a restart of enso: dispatch resumes the task on its own.
[ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == *"(enso stopped)" ]] && exit 0

case "$ENSO_TO_STAGE:${ENSO_BLOCK_KIND:-}:${ENSO_FROM_STAGE:-}" in
  blocked:stopped:*)
    exit 0 ;;
  blocked:decision:pm | blocked:decision:build | blocked:decision:qa)
    printf '%sQuestion on *%s*\n\n%s\n\n_Reply in this thread and I will carry on._\n' \
      "$mentions" "$title" "$message" | send "$WORKFLOW_CHANNEL" ;;
  blocked:*)
    printf '%s: *%s* (%s at %s): %s\n' "$([ "${ENSO_BLOCK_KIND:-}" = failure ] && echo Stopped || echo 'Needs you')" \
      "$title" "${ENSO_BLOCK_KIND:-blocked}" "${ENSO_FROM_STAGE:-?}" "${message:0:1500}" | send "" ;;
  signoff:*)
    pr="$(state "$ref" pr)"; head="$(state "$ref" head)"
    summary="$(stage_output "$ref" review)"
    # Only QA's plain-language part goes to the approver; the details stay on the task.
    qa="$(stage_output "$ref" qa | python3 -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"\*\*For the approver:?\*\*:?\s*(.*?)(?=\n\s*\*\*[A-Z][^*\n]*:?\*\*|\Z)", text, re.S)
out = m.group(1).strip() if m else text.strip().split("\n\n")[0]
print(out[:700])')"
    receipt="$({
      printf '%sReady for your approval: *%s*\n\n' "$mentions" "$title"
      [ -n "$summary" ] && printf '%s\n\n' "$summary"
      [ -n "$qa" ] && printf '*Checked on the preview:* %s\n\n' "$qa"
      [ -n "$pr" ] && printf 'Pull request and preview links: %s (version %s)\n\n' "$pr" "${head:0:8}"
      printf 'Should I merge this version? Reply *approve* in this thread, or tell me what to change.\n'
    } | "$ENSO_BIN" message send - --to "slack:$WORKFLOW_CHANNEL" --workspace "$ENSO_WORKSPACE" --json 2>/dev/null)" \
      || { echo "notify.sh: signoff not sent: $ref" >&2; exit 0; }
    # QA's Before/After screenshots (task refs of kind path) go into the notice's thread.
    thread="$(python3 -c 'import json, sys; r = json.loads(sys.argv[1]); print(r.get("ts") or r.get("message_id") or "")' "$receipt" 2>/dev/null || true)"
    shots="$("$ENSO_BIN" task show "$ref" --workspace "$ENSO_WORKSPACE" --json | python3 -c 'import json, os, re, sys
seen = []
for r in json.load(sys.stdin).get("refs") or []:
    v = str(r.get("value", ""))
    if r.get("kind") == "path" and re.match(r"(before|after)[^/]*\.(png|jpe?g)$", os.path.basename(v), re.I) \
            and os.path.isfile(v) and v not in seen:
        seen.append(v)
def pair(p):  # before.png, after.png, before-x.png, after-x.png
    base = os.path.basename(p).lower()
    rest = re.sub(r"^(before|after)", "", base)
    return (rest.startswith("-") or rest.startswith("_"), rest, not base.startswith("before"))
print("\n".join(sorted(seen, key=pair)[:6]))')"
    if [ -n "$thread" ] && [ -n "$shots" ]; then
      files=(); while IFS= read -r f; do files+=("$f"); done <<<"$shots"
      SLACK_UPLOAD_COMMENT="Before and after, from the preview:" \
        python3 "$here/slack-upload.py" "$WORKFLOW_CHANNEL" "$thread" "${files[@]}" >&2 \
        || echo "notify.sh: screenshots not uploaded: $ref" >&2
    fi ;;
esac
