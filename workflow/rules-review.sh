#!/usr/bin/env bash
# rules-review.sh REF: decide a task blocked on "Changed tests or check files need approval".
# Called by dispatch (lore-bridge.sh) for each such task.
#
# Claude, with no tools, reads the edits to the protected files since the task's trusted
# start, plus the brief, and answers approve or escalate:
#   approve   the edits only add or tighten tests, or update them for behaviour the brief
#             asks to change, and check-file edits are routine (a script, a dependency);
#             recorded with `enso workflow approve-rules`, reason in the message.
#   escalate  anything that could hide a regression: assertions removed or loosened, tests
#             skipped, thresholds or CI/lint settings relaxed. The operator gets the files
#             and the reviewer's reason, and approves by hand.
# Each version of the edits is judged once (state/REF.rules), so a tick never repeats it.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ref="${1:?usage: rules-review.sh REF}"
E() { env -u ENSO_RUN_ID "$ENSO_BIN" "$@" --workspace "$ENSO_WORKSPACE"; }

show="$(mktemp)"; out_file="$(mktemp)"; trap 'rm -f "$show" "$out_file" "$out_file.prompt"' EXIT
E task show "$ref" --json > "$show"
field() { python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); h = d.get("handoff") or {}
print({"msg": str(h.get("message", "")), "title": d.get("title", "")}[sys.argv[2]])' "$show" "$1"; }
msg="$(field msg)"; title="$(field title)"
# RULES_REVIEW_DRY=1 RULES_REVIEW_MSG="Changed tests…: a, b. Review them…" prints the verdict only.
[ -n "${RULES_REVIEW_MSG:-}" ] && msg="$RULES_REVIEW_MSG"
[[ "$msg" == "Changed tests or check files need approval:"* ]] || exit 0

files="${msg#Changed tests or check files need approval: }"; files="${files%%. Review them*}"
# The worktree and its trusted start, read-only from enso's database.
read -r wt start <<<"$(python3 - "${ENSO_HOME:-$HOME/.enso}/enso.db" "$ref" <<'PY'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("SELECT path, start_revision FROM _enso_worktrees WHERE ref=?", (sys.argv[2],)).fetchone()
print(*(row or ("", "")))
PY
)"
[ -d "$wt" ] || { echo "rules-review: no worktree for $ref" >&2; exit 0; }
[ -n "$start" ] || exit 0
head="$(git -C "$wt" rev-parse HEAD)"
mark="$here/state/$ref.rules"; key="$head $(printf '%s' "$files" | cksum | cut -d' ' -f1)"
[ -z "${RULES_REVIEW_DRY:-}" ] && [ "$(cat "$mark" 2>/dev/null)" = "$key" ] && exit 0

IFS=',' read -r -a list <<<"$files"
paths=(); for f in "${list[@]}"; do f="${f# }"; [ -n "$f" ] && paths+=("$f"); done
diff="$(git -C "$wt" diff "$start" "$head" -- "${paths[@]}" | head -c 60000)"
brief="$(stage_output "$ref" pm | head -c 6000)"
handoff="$(stage_output "$ref" build | head -c 2000)"

schema='{"type":"object","properties":{"verdict":{"type":"string","enum":["approve","escalate"]},"reason":{"type":"string"}},"required":["verdict","reason"]}'
prompt="You review edits an AI coding agent made to existing tests and check files, before a
person would have to. Approve only if every edit keeps or strengthens what the tests check:
new tests or cases, extra assertions, imports, fixtures, a count that grew because the
change adds items, or a test rewritten because the brief changes that behaviour on purpose
(the new test must check the new behaviour at least as strictly). For package.json and
similar files, approve routine additions (a script, a dependency, a version bump the change
needs). Escalate if anything removes or loosens an assertion without the brief requiring it,
skips or deletes a test, relaxes a threshold, timeout, lint or type setting, or changes CI,
or if you are unsure. Reason: one or two plain sentences naming what changed.

## Task
$title

## Brief (excerpt)
$brief

## Build's handoff
$handoff

## Diff of the protected files
$diff"

printf '%s' "$prompt" > "$out_file.prompt"
out="$(cd /tmp && timeout 600 "$(cat "$HOME/.config/enso-agent/claude-path" 2>/dev/null || echo claude)" -p --model opus --tools "" --strict-mcp-config \
  --no-session-persistence --output-format json --json-schema "$schema" < "$out_file.prompt" 2>/dev/null)" \
  || { echo "rules-review: reviewer did not answer for $ref" >&2; exit 0; }
printf '%s' "$out" > "$out_file"
verdict_of() { python3 -c 'import json, sys
r = json.load(open(sys.argv[1])); s = r.get("structured_output")
if not isinstance(s, dict):
    try: s = json.loads(r.get("result", ""))
    except Exception: s = {}
v = s.get("verdict") if s.get("verdict") in ("approve", "escalate") else "escalate"
print(v if sys.argv[2] == "verdict" else " ".join(str(s.get("reason") or "no reason given").split()))' "$out_file" "$1"; }
verdict="$(verdict_of verdict)"; reason="$(verdict_of reason)"

if [ -n "${RULES_REVIEW_DRY:-}" ]; then echo "$verdict: $reason"; exit 0; fi
if [ "$verdict" = approve ]; then
  res="$(E workflow approve-rules "$ref" --message "Approved by the test-edit reviewer (Claude): $reason" 2>&1)" || true
  case "$res" in
    *"still active"*|*"in use"*) echo "rules-review: $ref run still active; next tick" >&2; exit 0 ;;
  esac
  if [[ "$res" == *"budget exhausted"* ]]; then
    # Approval gates count as attempts; a task revised after review can run out of them.
    E workflow retry "$ref" --message "Test edits approved by the reviewer; the attempts went to approval gates." >/dev/null 2>&1 || true
    E task resume "$ref" --message "Resumed automatically: the edited tests were approved; hand off again." >/dev/null 2>&1 || true
  fi
  echo "$key" > "$mark"; echo "$ref: test edits approved ($reason)" >&2
else
  printf 'Needs you: *%s*: edited tests or check files need your approval.\n\nReviewer: %s\n\nFiles: %s\n\nIf they are fine: `enso workflow approve-rules %s --message "..."`\n' \
    "$title" "$reason" "$files" "$ref" | "$ENSO_BIN" message send - --workspace "$ENSO_WORKSPACE" >/dev/null \
    || { echo "rules-review: escalation not sent for $ref" >&2; exit 0; }
  echo "$key" > "$mark"; echo "$ref: test edits escalated ($reason)" >&2
fi
