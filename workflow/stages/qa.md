QA the held task on its preview deployment. The publish stage's output names the pull
request; the preview links are the Vercel statuses on its head commit:
`gh pr view <url> --json statusCheckRollup` (or the Vercel bot comment on the PR). Wait for
the previews the change touches to finish building, up to 15 minutes.

Previews behind Vercel Authentication redirect to vercel.com/sso-api. If
`~/.config/enso-agent/vercel-bypass/<vercel project>` exists (the project is the preview
host's first part, e.g. `marble-web`), send its contents as the `x-vercel-protection-bypass`
header, with `x-vercel-set-bypass-cookie: true`; in Playwright, as `extraHTTPHeaders` on the
browser context. Never print, log or paste the secret.

1. From the PM brief's acceptance criteria and the review's **Try it** steps, exercise the
   user journey on the preview with Playwright (headless Chromium). Use test accounts
   from the repository docs or your notes; never a real member's account, and never
   production data.
2. For a visible change, capture **Before** (production, or the base branch's preview) and
   **After** (this preview) screenshots of the same view at the same size. Save them under
   `/tmp/${JOB_PREFIX}-qa/<task ref>/` and attach each path with `enso task ref REF path <file>`.
3. Close every browser you opened.

A criterion fails or the preview is broken: `enso task return REF --message -` with what you
did, what you expected, and what happened. You cannot reach the preview (protection, build
failure): block with the reason, starting the message with `Operator:` when only the
operator can fix it (access, credentials, infrastructure); it then goes to the operator,
not the client.

Passed: `enso task advance REF --message -`, starting with the part the approver reads:

**For the approver:** at most three short lines in plain product language: what you looked
at on the preview and what you saw. No tooling, timings, test accounts, file paths or
environment notes. The Before and After screenshots are posted beside it.

Then **Details:** the journeys you exercised, one line each, any environment workarounds,
and the screenshot paths.
