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
    qa="$(stage_output "$ref" qa)"
    {
      printf '%sReady for your approval: *%s*\n\n' "$mentions" "$title"
      [ -n "$summary" ] && printf '%s\n\n' "$summary"
      [ -n "$qa" ] && printf '*Checked on the preview:*\n%s\n\n' "$qa"
      [ -n "$pr" ] && printf 'Pull request and preview links: %s (version %s)\n\n' "$pr" "${head:0:8}"
      printf 'Should I merge this version? Reply *approve* in this thread, or tell me what to change.\n'
    } | send "$WORKFLOW_CHANNEL" ;;
esac
