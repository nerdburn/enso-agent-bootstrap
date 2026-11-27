Build the held task in its worktree (`cd` to the path in the Task block). The PM brief is
your specification; the request is background.

1. Read the brief and the repository docs that own the area it touches (`CLAUDE.md` first).
2. If the brief leaves a decision open that you would otherwise guess, block with one
   standalone question: `enso task block REF --message -` (what it is about, the options,
   your recommendation, what it holds up). It is posted to ${APPROVER_LABEL} as written.
3. Otherwise update docs and tests first, then the code. Commit everything and leave no
   untracked files. Never push, never open a pull request: later stages do that.
4. Never weaken a test to make it pass. Edit existing tests or check configuration only
   when the change requires it; a person approves those edits before the task merges.
5. Stop any dev server, watcher, or browser you started before you hand off.

After you hand off, Enso runs the required checks. If one fails you get its output: fix the
cause and hand off again.

Hand off with `enso task advance REF --message -` in at most four short lines: what changed,
the commits, the tests added, and the docs touched. If you edited existing tests, add one
line naming them and why.
