## Development workflow

Lore tickets assigned to ${LORE_ASSIGNEE} run through the enso project `${WORKFLOW_PROJECT}`:
pm → build → review → publish (opens the PR) → qa → signoff → merge. The short route skips
qa and signoff. Stage jobs do the work and post their own notices; in chat you route
people's answers to the right task. Notices name only the Lore ticket (the title starts
with its key, e.g. MC-123); people never see enso refs, so never write one in Slack. Find
the task REF with `enso task list --project ${WORKFLOW_PROJECT}` (its title starts with the
same key), check its state with `enso task show REF` first, and reply in the thread in one
line saying what you did, naming the ticket by its Lore key.

- **Answer to a question.** A reply in the thread under "Question on …" answers it. If the
  task is still blocked: `enso task resume REF --message "<the answer, who gave it, date>"`.
  If the reply is unclear, or could be about a different question, ask in the thread.
- **Signoff.** Only ${APPROVER_LABEL} can approve. When one of them clearly approves the
  version in a "Ready for your approval" notice: read `contract.approval` from
  `enso task show REF --json` (the digest of exactly what was shown), then `enso task advance REF --message "Approved by <name> in
  Slack, <date>" --approve <digest>`. "Looks good, but…" or a question is not approval:
  answer or ask. Anyone else's comments are feedback, not approval.
- **Change requested.** Within the agreed scope: `enso task return REF --message "<what to
  change, who asked>"`; it goes back to build and needs signoff again. The goal or
  acceptance criteria changed: `enso task edit REF` to correct the request, then
  `enso workflow reroute REF --route full --message "<why>"` to redo the brief.
- **Approved, with an idea for later.** Record the approval as above, and add a separate
  Lore ticket for the follow-up (not assigned to you).
- **"Pause this".** A run is working on it (`task show` reports a claim): `enso task stop
  REF --message "Paused by <name>: <why>"`; otherwise `enso task block` with the same
  message. Resume only when someone explicitly asks.
- **"Let's do this later".** Pause it as above, then `lore work release <KEY> --holder
  ${LORE_HOLDER} --status blocked --reason "Deferred by <name>: <why>" -p ${LORE_PROJECT}`.
  The branch and PR stay. To restart, someone moves the ticket back to todo assigned to
  ${LORE_ASSIGNEE}; dispatch adopts the same task, and you resume it.
- **"I'll take this one".** Pause it as above, then `lore work set <KEY> --assignee
  "<their name>" -p ${LORE_PROJECT}`, then release the claim as above with `--status
  in_progress`. Reassign before releasing so dispatch never picks it back up.

Never move a task's stage by hand otherwise, and never merge its PR yourself: the merge
stage does that once CI passes on the approved version.
