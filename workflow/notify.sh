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
# Edited tests waiting for approval: dispatch's reviewer (rules-review.sh) approves sound
# edits and sends the operator only the ones it escalates.
[ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == "Changed tests or check files need approval:"* ]] && exit 0
# A handoff refused because the operator changed the workflow mid-run: dispatch resumes it.
[ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == "workflow changed during execution"* ]] && exit 0

# A remote worker's infrastructure error: dispatch resumes it, and tells the operator only
# if it keeps failing.
[ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == *"ended (error): enso-worker:"* ]] && exit 0

# Operator notices are one short line: the ticket key and what is needed.
key="$(ticket "$title")"
# A question only the operator can answer (access, credentials): never to the client.
if [ "$ENSO_TO_STAGE" = blocked ] && [[ "$message" == Operator:* ]]; then
  operator "*$key* needs you: $(gist "${message#Operator:}" 300)"
  exit 0
fi

case "$ENSO_TO_STAGE:${ENSO_BLOCK_KIND:-}:${ENSO_FROM_STAGE:-}" in
  blocked:stopped:*)
    exit 0 ;;
  blocked:decision:pm | blocked:decision:build | blocked:decision:qa)
    printf '%sQuick question on *%s*:\n%s\n' "$mentions" "$title" "$message" | send "$WORKFLOW_CHANNEL" ;;
  blocked:failure:*)
    operator "*$key* stopped at ${ENSO_FROM_STAGE:-?}: $(gist "$message")" ;;
  blocked:*)
    operator "*$key* needs you at ${ENSO_FROM_STAGE:-?}: $(gist "$message")" ;;
  signoff:*)
    # Short: what was done, anything to confirm, the link, "can I ship it?". Review's other
    # sections and QA's report stay on the task; the screenshots go into the thread.
    pr="$(state "$ref" pr)"
    # Preview links from the Vercel bot's comment on the PR (one per Vercel project; an
    # API-only project has nothing to look at). The statuses only link to the dashboard.
    previews=""
    [ -n "$pr" ] && previews="$(gh pr view "$pr" -R "$WORKFLOW_REPO" --json comments \
      --jq '.comments[] | select(.author.login | test("vercel"; "i")) | .body' 2>/dev/null \
      | grep -oE 'https://[a-z0-9-]+\.vercel\.app' | sort -u | grep -vE '^https://[a-z0-9-]*api-git-' | head -4 || true)"
    receipt="$(stage_output "$ref" review | python3 -c 'import re, sys
text, mentions, title, pr, previews = sys.stdin.read(), *sys.argv[1:]
def field(name):
    m = re.search(r"\*\*" + name + r":?\*\*:?[ \t]*(.*?)(?=\n\s*\*\*[A-Z][^*\n]*:?\*\*|\Z)", text, re.S)
    return m.group(1).strip() if m else ""
changed = " ".join(field("Changed").split()) or " ".join(text.strip().split("\n\n")[0].split())[:200]
asks = [re.sub(r"^[-*•\d.)\s]+", "", l).strip() for l in field("To decide").splitlines()]
asks = [a for a in asks if a]
out = f"{mentions}I finished *{title}*" + (f": {changed[:1].lower() + changed[1:]}" if changed else ".")
if asks:
    out += "\n\nBefore I ship it, can you confirm:\n" + "\n".join("• " + a for a in asks)
links = [u for u in previews.split() if u]
def label(u):  # marble-web-git-athena-mc-1-team.vercel.app -> web
    return u.split("//", 1)[1].split("-git-", 1)[0].split("-")[-1]
if len(links) == 1:
    ask = f"Take a peek at the preview ({links[0]}) and let me know: can I ship it?"
elif links:
    ask = "Take a peek at the previews (" + ", ".join(f"{label(u)}: {u}" for u in links) + ") and let me know: can I ship it?"
elif pr:
    ask = f"Here is the pull request: {pr}. Can I ship it?"
else:
    ask = "Can I ship it?"
out += f"\n\n{ask} Reply *approve*, or tell me what to change."
print(out)' "$mentions" "$title" "$pr" "$previews" \
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
