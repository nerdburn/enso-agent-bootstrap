Write the brief for the held task. Do not change code.

The repository is checked out at `${REPO_DIR}` on `${WORKFLOW_BASE}`. Read it there; never
edit, commit, install, or run its dev server or tests from it. Lore (`lore_grep`,
`lore_read`, `lore_recall`) holds the client's earlier decisions and the ticket's history;
the ticket key is in the task title.

1. Read the task, the ticket's history in Lore, and the code the change touches.
2. Draft the brief:
   - **Goal**: one line, in the client's terms.
   - **Acceptance criteria**: bullets someone can check on a preview.
   - **Out of scope**.
   - **Surfaces**: web, admin, API, mobile.
   - **Decisions**: each one with who made it, when, and where (Lore item, Slack, meeting).
   - **Notes for Build**: files, risks, data or migration concerns.
   - **For the PR** (only when needed): anything the pull request must tell people, such as
     follow-ups for other teams or decisions still owed. Put it under a `## For the PR`
     heading; publish copies that section into the PR description as written.
3. If Build would have to guess a customer decision, ask instead. First save the draft:
   `enso task note REF "<the draft brief>"`. Then block with exactly one question:
   `enso task block REF --message -`. The message is posted to ${APPROVER_LABEL} as written,
   so it must stand alone: what this is about and why it is being asked, the options in
   plain words, your recommendation, and what it holds up. No ticket keys, task refs, or
   jargon in it. Then end the turn.
4. When you are resumed, the answer is in the Task block and your draft in the timeline.
   Record the answer under Decisions (who, date) and finish the brief. If the answer is
   unclear or raises a new decision, block again with one question.
5. Choose the route:
   - `full` for anything a member, admin, or the client would see or notice, and whenever
     unsure. It adds QA on the preview and the client's signoff.
   - `short` only for internal fixes with no visible change that the checks fully cover.
6. Hand off: write the brief to a file under `/tmp`, then
   `enso task advance REF --route <route> --output-file <file> --message "<one line>"`.
