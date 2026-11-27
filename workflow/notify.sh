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

# A question only the operator can answer (access, credentials): never to the client.
if [ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == Operator:* ]]; then
  printf 'Needs you: *%s* (%s at %s)\n\n%s\n' "$title" "${ENSO_BLOCK_KIND:-blocked}" "${ENSO_FROM_STAGE:-?}" \
    "$(printf '%s' "${message#Operator:}" | sed '1s/^ *//' | cut -c1-3000)" | send ""
  exit 0
fi

case "$ENSO_TO_STAGE:${ENSO_BLOCK_KIND:-}:${ENSO_FROM_STAGE:-}" in
  blocked:stopped:*)
    exit 0 ;;
  blocked:decision:pm | blocked:decision:build | blocked:decision:qa)
    printf '%sQuick question on *%s*:\n%s\n' "$mentions" "$title" "$message" | send "$WORKFLOW_CHANNEL" ;;
  blocked:*)
    printf '%s: *%s* (%s at %s): %s\n' "$([ "${ENSO_BLOCK_KIND:-}" = failure ] && echo Stopped || echo 'Needs you')" \
      "$title" "${ENSO_BLOCK_KIND:-blocked}" "${ENSO_FROM_STAGE:-?}" "${message:0:1500}" | send "" ;;
  signoff:*)
    # Short: what was done, anything to confirm, the link, "can I ship it?". Review's other
    # sections and QA's report stay on the task; the screenshots go into the thread.
    pr="$(state "$ref" pr)"
    receipt="$(stage_output "$ref" review | python3 -c 'import re, sys
text, mentions, title, pr = sys.stdin.read(), *sys.argv[1:]
def field(name):
    m = re.search(r"\*\*" + name + r":?\*\*:?[ \t]*(.*?)(?=\n\s*\*\*[A-Z][^*\n]*:?\*\*|\Z)", text, re.S)
    return m.group(1).strip() if m else ""
changed = " ".join(field("Changed").split()) or " ".join(text.strip().split("\n\n")[0].split())[:200]
asks = [re.sub(r"^[-*•\d.)\s]+", "", l).strip() for l in field("To decide").splitlines()]
asks = [a for a in asks if a]
out = f"{mentions}I finished *{title}*" + (f": {changed[:1].lower() + changed[1:]}" if changed else ".")
if asks:
    out += "\n\nBefore I ship it, can you confirm:\n" + "\n".join("• " + a for a in asks)
peek = f"Take a peek ({pr}) and let me know: can" if pr else "Can"
out += f"\n\n{peek} I ship it? Reply *approve*, or tell me what to change."
print(out)' "$mentions" "$title" "$pr" \
      | "$ENSO_BIN" message send - --to "slack:$WORKFLOW_CHANNEL" --workspace "$ENSO_WORKSPACE" --json 2>/dev/null)" \
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
def rest(p):
    return re.sub(r"^(before|after)", "", os.path.basename(p).lower())
paired = {rest(p) for p in seen if os.path.basename(p).lower().startswith("before")} & \
         {rest(p) for p in seen if os.path.basename(p).lower().startswith("after")}
def order(p):  # complete before/after pairs first (the plain one first), then lone shots
    r = rest(p)
    return (r not in paired, r[:1] in "-_", r, not os.path.basename(p).lower().startswith("before"))
print("\n".join(sorted(seen, key=order)[:8]))')"
    if [ -n "$thread" ] && [ -n "$shots" ]; then
      files=(); while IFS= read -r f; do files+=("$f"); done <<<"$shots"
      SLACK_UPLOAD_COMMENT="Before and after:" \
        python3 "$here/slack-upload.py" "$WORKFLOW_CHANNEL" "$thread" "${files[@]}" >&2 \
        || echo "notify.sh: screenshots not uploaded: $ref" >&2
    fi ;;
esac
