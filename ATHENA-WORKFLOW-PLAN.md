# Athena-managed software workflows for Marble

Design proposal for review · 2026-11-26

Athena is Marble’s permanent manager in Slack. She holds the Lore claim, runs the Enso workflow, delegates individual stages to temporary workers, and brings decisions back to the client. Kristin is Marble’s proposed client approver. The same workflow should work for another client by changing the project configuration.

## Ownership and duplicate prevention

| Owner | Responsibility |
| --- | --- |
| Lore | Keep the customer-facing work item, its assignee and current claim holder, status, decisions, and links to work in progress. |
| Enso on Athena’s VM | Own one unfinished task per Lore ticket. Track its stage, accepted work, pending question or approval, and current worker attempt. Route Slack requests and scheduled dispatch through the same claim and task-creation path. |
| Temporary worker | Execute the assigned stage in a Vercel Sandbox. Return a draft, commit, test result, or question to Athena. Only the manager claims tickets, advances the workflow, and speaks for it in Slack. |

Lore already supports human claims, refuses a conflicting ordinary claim, and keeps a silent claim until it is explicitly released. Its Enso bridge claims an assigned ticket, uses `--unique-ref lore:<KEY>` to create or adopt an unfinished task, and reconciles missed stage updates. Enso enforces unique refs within one installation. Two independent Enso installations sharing Athena’s holder identity would undermine this design. [Lore bridge](https://github.com/nerdburn/lore/blob/b91d02f/integrations/enso/lore_bridge.py) · [Lore claim tests](https://github.com/nerdburn/lore/blob/b91d02f/test/work-claim.test.ts) · [Enso task creation](https://github.com/nerdburn/enso/blob/57c1f81/src/enso/tasks.py)

Authority to instruct Athena comes from Enso’s existing workspace bindings: owner DMs and the channels bound to the Marble workspace. Enso treats every participant in a bound channel as trusted, so this plan adds no separate permission list. Kristin as the named signoff approver is a Marble project setting on top of that.

## Remote workers and scale

**Goal.** A customer can ask Athena for 20 things at once, or ask her to work through the whole Lore backlog, and the work runs in parallel without exhausting her VM. Athena’s VM has 16 GB and ran out of memory on 2026-11-19 with only two Claude runs active, because dev servers and test processes piled up beside them.

**Verdict.** Achievable. Moving agent stages into sandboxes takes the agent, its dev servers, and its test runs off the VM, so memory stops being the limit. The limits that replace it are Claude subscription usage, client attention, and merge contention. They are listed below and decide how many workers are useful.

### What runs where

| Place | Runs |
| --- | --- |
| Athena’s VM | Enso tasks, Lore claims, Slack, the merge queue, and one small supervisor process per active worker. |
| One Vercel Sandbox per stage attempt | The repository checkout, the coding agent, dev servers, and the project’s check commands. Each vCPU comes with 2 GB of memory. |

### Why Vercel Sandbox

Workers run in Vercel Sandboxes. Each sandbox has its own memory, billed only while it runs, and Athena can create, drive, and stop one from the CLI with a token. A base snapshot makes starts fast. The account already exists, and Marble’s previews deploy there.

exe.dev VMs are not used for workers. Their memory comes out of the plan quota shared with every other agent VM, capacity for a 20-worker peak would be paid for all month, and Athena cannot create VMs because that control plane is reachable only from the operator’s laptop.

### Use the Vercel Sandbox CLI directly

fxs is built for a person at a terminal. It attaches the agent to the caller’s terminal, allocates sandbox names from a lock file on the local machine, and has no command that sends a prompt and returns a result. Underneath it calls `vercel sandbox create`, `exec`, and `stop`, and those commands already cover unattended use. Athena should call them through one small worker command and borrow fxs’s base-snapshot idea: tools, agent CLI, and a warm clone of each repository baked into a snapshot so a worker starts in seconds. fxs stays useful for a person who wants to attach to a running worker. [fxs](https://github.com/fazxes/fxs)

| Worker operation | How |
| --- | --- |
| Launch | `vercel sandbox create --name <project>-<task>-<stage>-a<attempt> --snapshot <base> --tag task=<ref> --timeout <limit>`. Sandbox names are unique per Vercel project, so a second launch for the same attempt is refused. That is the duplicate guarantee, and it survives an Athena restart. |
| Run | Start the agent detached inside the sandbox with the stage brief. It commits to the task branch, pushes, and writes a result file: summary, any question, and the exit code of each check command. |
| Supervise | The supervisor polls for the result file. After a restart Athena finds workers by tag with `vercel sandbox list` and resumes polling. If a worker’s state is unknown, the task waits. |
| Collect | Fetch the pushed branch into the task’s Enso worktree so Enso’s candidate and evidence records stay as they are today. |
| Stop | `vercel sandbox stop`, then remove once the branch and result are saved. A nightly sweep removes sandboxes with no matching unfinished task, like agent-reaper does for local processes. |

Only the current attempt can submit an accepted result, and a replacement starts only after the previous sandbox has stopped. A fresh Lore heartbeat says the manager is checking in. Worker health is the supervisor’s job.

The repository’s CI decides whether a PR can merge: Athena merges only when the PR’s required GitHub checks have passed on the candidate commit. The worker script also runs the project’s check commands and records each exit code, so a pass is never the agent’s own claim, but those results are only fast feedback for Build and Review and never authorize a merge. Running the checks in Athena’s local worktree would bring the memory load back.

The first version can sit where claude-gate sits today, as the command Enso’s claude provider runs, going remote for stage runs and staying local for chat turns. Whether a stage run exposes enough to that command (task, stage, attempt) needs to be confirmed. The longer-term home is a remote executor in Enso.

### Access inside a worker

| Item | Approach |
| --- | --- |
| Claude | A long-lived token from `claude setup-token`, passed as an environment variable. Copies of the VM’s login file would each try to refresh the same session. Workers stay on the subscription. |
| GitHub | Keep the inputagents token out of the sandbox. `vercel sandbox create` can add a request header for one domain from an environment variable on Athena’s side, and can restrict outbound traffic to an allowed domain list. To be verified with git over HTTPS. |
| Git identity | The inputagents noreply address. Vercel blocked Athena’s preview deploys on 2026-11-23 when her commits used a different author. |
| Lore | None. The Lore MCP server is reachable only through the VM’s exe.dev integration, so the stage brief has to carry everything the worker needs. |
| Slack tokens, Stripe key | Never sent to a worker. |
| Code pause | Athena launches no Build worker while the pause is on and stops running ones when it is switched on. The hook is also baked into the base snapshot. |
| Vercel account | Sandboxes belong to an Input Logic project, with a token scoped to it. Athena’s Vercel CLI is currently logged in to a personal account that can see Marble’s team. |

### What limits the number of workers

| Limit | Today | Change |
| --- | --- | --- |
| claude-gate | Three concurrent Claude runs on the VM, counting every run. | Remote stage runs get their own cap, so 20 workers do not queue Slack replies behind them. Start at 5. |
| Enso project concurrency | `max_concurrency` defaults to 1, and to 3 with the development preset. | Set it to the worker cap. |
| Lore admission | The bridge claims up to three new assigned tickets per dispatch tick, with no cap on the total held. Over a few ticks it would claim the whole backlog. | Admit by priority only while unfinished tasks are under a work-in-progress limit, so unclaimed tickets stay open to people. |
| Claude subscription | All workers share Athena’s seat. | This is the real ceiling. Twenty concurrent sessions will exhaust a seat’s usage window quickly. Decision needed: a pool of seats for workers, or accept a lower cap. |
| Vercel Sandbox plan | Input Logic is on Pro: 10,000 concurrent sandboxes, 24-hour sessions, up to 8 vCPUs and 16 GB each, 64 GB disk. | Not a constraint. A 4 vCPU, 8 GB worker costs about $0.17 an hour for memory plus $0.128 per CPU-hour actually used, so at most about $0.68 an hour. Default workers to 4 vCPUs, not fxs’s 8. Snapshots expire 30 days after last use unless set otherwise. [Pricing](https://vercel.com/docs/vercel-sandbox/pricing) |
| Client attention | One approver. | Twenty questions or signoffs at once will not get answered. Batch them into a digest and cap the tasks waiting on the client. |
| Merge | One monorepo, `marble-web`. | Merge one PR at a time. Each merge moves `main` under the others. Overlapping tickets run in sequence, using Enso’s `--after` dependency. |
| Shared staging database | One Neon `staging` branch. | Tickets with migrations get their own Neon branch, or run one at a time. |

### Working through the backlog

Run it in two passes. The PM pass goes over every item first. It needs no sandbox, and its questions reach the client as one digest. Build then runs in waves up to the worker cap, in priority order, admitting a new ticket only when one finishes or parks. An item waiting on the client releases its worker, so unanswered questions do not hold capacity.
## Development stages for Marble

Enso supports a custom stage pipeline per project, and other agent VMs may define different stages. This is where Marble starts.

| Stage | Handoff |
| --- | --- |
| PM | Clarify the goal and acceptance criteria. A well-specified ticket passes through quickly. Save the brief and any customer decisions for Build. |
| Build | Produce the candidate commit, a summary of the change, and evidence from the project’s required checks. |
| Review | A second agent reviews the exact candidate against the brief. Accept it or return specific findings to Build. |
| QA | Exercise the relevant user journey on that candidate. Marble configures the checks for each surface, such as a web flow or mobile simulator test. |
| Client signoff, when required | Athena presents the reviewed candidate to the configured approver and waits for explicit approval. |
| Merge | Merge the approved PR head after required checks pass. Record the resulting commit on the Lore item. Deployment is a project-specific step when the ticket calls for it. |

The default full route is **PM → Build → Review → QA → Client signoff → Merge**. For a routine internal fix covered by automated checks, the short route is **PM → Build → Review → Merge**. A project can require QA without client signoff. For Marble, default customer-visible UI and interaction changes to signoff, and let an authorized person request signoff on any ticket before merge. Record the selected route on the task.

## Slack questions, feedback, and signoff

Any stage can ask a question. For example, a PM worker might need Kristin to decide whether invited members can skip onboarding. The worker returns its draft and question. Athena saves both, blocks the task, records the reason in Lore, and posts in the appropriate Marble thread. The worker can stop. Downstream work on that ticket waits while independent tickets continue.

Persist the task, stage, outstanding question, and Slack thread together. When an authorized person answers, Athena records the decision and resumes the same stage with its saved work. Consume a Slack event once and verify that the question is still open. If a reply could refer to an older question or its meaning is unclear, ask in-thread. Enso already documents decision blocks, human stages, and resuming a task with an answer. [Enso workflow hooks](https://github.com/nerdburn/enso/blob/57c1f81/src/enso/bundled/skills/enso-projects/references/workflows.md) · [Enso task actions](https://github.com/nerdburn/enso/blob/57c1f81/src/enso/bundled/skills/enso-projects/references/tasks.md)

At signoff, Athena keeps the PR open and sends Kristin a short summary, labeled **Before** and **After** screenshots of the same view and/or a Vercel preview tied to the reviewed commit. For an interaction change, include what to try. Ask explicitly whether to merge that version. Record the approver, Slack reply, and commit. Immediately before merge, verify that the ticket is active, required checks pass, and the PR still contains the approved change. With many PRs in flight `main` moves constantly, so a clean rebase with passing checks keeps the approval. A content change or a conflict resolution requires fresh signoff.

| Client feedback at any stage | Proposed handling |
| --- | --- |
| Answers an open question or asks how to try the preview | Resume the waiting stage with the answer, or answer the question and keep waiting for signoff. |
| Requests a change within the agreed scope | Return to Build. Review the revised candidate, repeat applicable checks, and renew any required signoff. Keep the accepted PM brief. |
| Changes the goal or acceptance criteria | Return to PM, confirm the revised scope, then redo stages whose inputs changed. |
| Approves this version and asks for an enhancement later | Record the explicit approval and create a linked, deferred follow-up. Clarify ambiguous wording before merging. |

## Pause, deferral, and human claims

An authorized pause immediately holds stage advancement and merge. Athena preserves the current work and confirms the worker has stopped before reporting it as freed or transferring the claim. Record who requested the change, why, the saved stage and artifacts, and any agreed restart condition on the Lore item.

| Request or event | Lore and Enso behavior |
| --- | --- |
| Waiting for a decision or signoff | Mark blocked and retain Athena’s claim. Release the worker. The matching answer or approval can resume the task. |
| “Pause this for now” | Mark blocked and retain Athena’s claim. Park the task until an authorized resume instruction or an explicitly agreed restart condition. An ordinary thread reply leaves it paused. |
| “Let’s do this later” about the current ticket | Park the task, preserve the draft, branch, or PR, and mark the ticket `blocked` with the reason. Release Athena’s claim after the worker stops. The bridge dispatches only `todo` tickets, so the item stays out of automatic dispatch. Reactivation requires a fresh claim and a check of the saved work before the same task continues. |
| A human claims available work | Allow an ordinary claim on an eligible, unclaimed item. Athena skips human-held work, including work assigned to her. If Athena already holds the item, an ordinary second claim is refused. Commenting, pausing, and signing off do not require taking the claim. |
| “I’ll take this one” while Athena holds it | Park the task and stop its worker. Reassign the ticket to the person before releasing Athena’s claim. The bridge dispatches only tickets assigned to Athena, so there is no interval in which it could restart the work. Reserve forced takeover with a recorded reason for recovery of a stranded claim. |

No new Lore status is needed. Deferred work uses the existing `blocked` status with a recorded reason. Claim release, parking, and status transitions must recover safely if one system updates before the other. [Lore work statuses](https://github.com/nerdburn/lore/blob/b91d02f/src/work.ts)

## Repository boundaries and rollout

Keep the three repositories and manage the rollout as one initiative. **Lore** owns work records, claims, and its Enso bridge. **Enso** owns workflow execution, recovery, human gates, and the reusable remote-worker interface. **enso-agent-bootstrap** installs and configures the shared development preset and Marble’s overrides, including repositories, check commands, Slack routing, approver identity, and rollout settings.

Bootstrap currently defaults to Enso 0.5.1. The reviewed Enso 0.6.0 release includes the unique-ref feature the bridge requires. Athena’s installed Enso and Lore versions, bridge configuration, and live behavior remain unverified. [Bootstrap installer](install.sh) · [Enso changelog](https://github.com/nerdburn/enso/blob/57c1f81/CHANGELOG.md)

**Pilot, in three steps**, so a failure points at one thing:

1. **Question round trip, no sandbox.** One Marble ticket, a local PM stage, and one real customer decision. Athena claims the ticket and saves the question and draft. Restart Athena while waiting and deliver Kristin’s answer twice. Success is one Lore claim, one unfinished Enso task, one recorded answer, and one accepted brief handed to Build.
2. **One remote Build worker.** Launch it, restart Athena mid-run, and attempt a second launch for the same attempt. Success is one sandbox, one recovered result, and one pushed candidate with recorded check results.
3. **Five tickets at once.** Watch VM memory, Claude usage, sandbox cost, and how the merge queue handles a moving `main`. Raise the worker cap from what this shows.

### Questions for the reviewer

1. Can every admission path adopt the existing Enso task after a crash between Lore claim and task creation? Can the worker launch path recover a lost response without starting a second worker?
2. How should the manager persist a pending Slack question and distinguish clarification, pause, approval, and takeover across a restart?
3. How should claim release, reassignment, and the parked task be ordered so a delayed worker cannot submit work after a pause or handoff?
4. Does a stage run give the provider command enough to launch and re-find its worker, or does Enso need a remote executor first? Does header injection work for git over HTTPS? What are the Vercel Sandbox plan’s concurrency, session-length, and cost limits?
5. How many Claude seats should the worker pool use, and what worker cap follows from that?
6. How should the PR merge operation enforce the approved head and handle a pause racing with merge? Enso’s documented integration lands work locally. Identify the additional PR operation needed for Marble and its recovery behavior.
