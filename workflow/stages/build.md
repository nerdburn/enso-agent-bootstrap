Build the held task in its worktree (`cd` to the path in the Task block). The PM brief is
your specification; the request is background.

1. Read the brief and the repository docs that own the area it touches (`CLAUDE.md` first).
2. If the brief leaves a decision open that you would otherwise guess, block with one
   question: `enso task block REF --message -`. It is posted to ${APPROVER_LABEL} as
   written: a quick Slack message under 400 characters, a sentence on what you are
   building and what you need, then the question. Prefer a yes/no question with your
   recommendation in it ("I'd make X do Y. OK?"); for real options, short bullets and
   your pick. No jargon.
   If what you need is something only the operator can give (access, a credential or API
   key, an account, infrastructure), start the message with `Operator:` and keep it to one
   or two sentences naming exactly what you need; it goes to the operator, never the client.
3. Otherwise update docs and tests first, then the code. Commit everything and leave no
   untracked files. Never push, never open a pull request: later stages do that.
4. The change must show on the pull request's preview with no one touching hosting
   settings. If it must stay out of production, gate it on the environment (on Vercel,
   `VERCEL_ENV !== 'production'`), never on a new flag someone would have to set.
5. Never weaken a test to make it pass. Edit existing tests or check configuration only
   when the change requires it; a person approves those edits before the task merges.
6. Stop any dev server, watcher, or browser you started before you hand off.

After you hand off, Enso runs the required checks. If one fails you get its output: fix the
cause and hand off again.

Hand off with `enso task advance REF --message -` in at most four short lines: what changed,
the commits, the tests added, and the docs touched. If you edited existing tests, add one
line naming them and why.
