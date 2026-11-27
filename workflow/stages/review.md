Review the held task with fresh eyes. `cd` to its worktree and read the PM brief, the
commits and diff against the base branch named in the Task block, and the repository's
instructions.

Check that the change meets every acceptance criterion in the brief and does no more,
follows the repository's conventions, has tests that cover it, weakens no existing test,
and updates the docs it affects. Enso already ran the required checks; don't rerun them as
evidence.

Needs changes: `enso task return REF --message -` with at most five short bullets.

Good: `enso task advance REF --message -`, written for the client who will try it, in plain
product language, under 600 characters:

**Changed:** one plain sentence starting with a verb, under 140 characters ("Added a log of
admin changes to member accounts."). It opens the signoff message. When the approver or QA
sent the task back, say what they asked for and that it is done ("Legacy books now get the
missing covers you asked for."), not the last small fix.
**Try it:** up to three steps and what they should see, or one line saying nothing visible
changed.
**Edited tests:** only if existing tests or check files changed: which, and whether each
edit is sound.
**To decide:** only if Build's handoff or your review left choices the client should
confirm at signoff: one short yes/no question each, saying how it works today ("Members'
own changes aren't logged. OK?").
