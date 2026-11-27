#!/usr/bin/env python3
"""Render the development workflow (workflow/) into an enso workspace from conf values.

Called by lib/workflow.sh with the conf's variables in the environment. Writes
  workspaces/<ws>/projects/<KEY>/{PROJECT.md, workflow.env, scripts}
  workspaces/<ws>/jobs/<prefix>-<stage>/JOB.md and <prefix>-lore-dispatch/JOB.md
  the "Development workflow" section of the workspace AGENTS.md
Every file is regenerated on each run; `enabled:` in PROJECT.md and in each JOB.md is
kept as it is, so turning stages on and off is an operator action, never a re-run.
Standard library only.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "workflow"
SCRIPTS = ("common.sh", "stage_output.py", "lore-bridge.sh", "notify.sh", "publish-pr.sh", "merge-pr.sh", "slack-upload.py", "refresh-branch.sh", "rules-review.sh")
# stage -> (timeout seconds, kind)
STAGES = {
    "pm": (1800, "agent"),
    "build": (3600, "agent"),
    "review": (1800, "review"),
    "publish": (600, "command"),
    "qa": (2700, "agent"),
    "merge": (3600, "command"),
}
MARK_START = "<!-- enso-agent-bootstrap:workflow -->"
MARK_END = "<!-- /enso-agent-bootstrap:workflow -->"


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        sys.exit(f"configure_workflow: {name} is required")
    return value


def q(value: str) -> str:
    """A YAML-safe scalar: JSON strings are valid YAML."""
    return json.dumps(value)


def enabled(path: Path) -> bool:
    if not path.exists():
        return False
    match = re.search(r"^enabled:\s*(true|false)\s*$", path.read_text(), re.M)
    return bool(match and match.group(1) == "true")


def write(path: Path, text: str, mode: int = 0o600) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    changed = not path.exists() or path.read_text() != text
    if changed:
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text)
        tmp.chmod(mode)
        tmp.replace(path)
    else:
        path.chmod(mode)
    return changed


def agent_block(spec: str) -> str:
    provider, model, effort = (spec.split("/") + ["", "", ""])[:3]
    if not (provider and model and effort):
        sys.exit(f"configure_workflow: agent must be provider/model/effort, got {spec!r}")
    return f"agent:\n  provider: {provider}\n  model: {model}\n  effort: {effort}\n"


def main() -> None:
    home = Path(env("ENSO_HOME"))
    workspace = env("CHANNEL_WORKSPACE")
    key = env("WORKFLOW_PROJECT")
    if not re.fullmatch(r"[A-Z][A-Z0-9]{1,9}", key):
        sys.exit("configure_workflow: WORKFLOW_PROJECT must be 2-10 uppercase letters/digits")
    prefix = key.lower()
    name = env("WORKFLOW_NAME", key.title())
    repo_dir = env("WORKFLOW_REPO_DIR")
    base = env("WORKFLOW_BASE")
    approvers = env("WORKFLOW_APPROVERS").split()
    approver_label = env("WORKFLOW_APPROVER_LABEL", " and ".join(f"<@{u}>" for u in approvers))
    # People who may also sign off without being mentioned on every notice (an operator
    # approving on the approver's behalf): "Shawn (<@U…>), on Kristin's behalf".
    delegates = os.environ.get("WORKFLOW_DELEGATES", "").strip()
    signoff_label = f"{approver_label}, or {delegates}" if delegates else approver_label
    agent = env("WORKFLOW_AGENT_SPEC")
    review_agent = env("WORKFLOW_REVIEW_AGENT", agent)
    lore_project = env("LORE_PROJECT")
    assignee = env("LORE_ASSIGNEE")
    holder = env("LORE_HOLDER")

    ws_dir = home / "workspaces" / workspace
    if not ws_dir.is_dir():
        sys.exit(f"configure_workflow: workspace {ws_dir} does not exist")
    project_dir = ws_dir / "projects" / key
    jobs_dir = ws_dir / "jobs"
    project_md = project_dir / "PROJECT.md"

    # Build in a Vercel Sandbox (lib/worker.sh): its checks run there too, on the candidate,
    # and this VM's worktrees need no dependencies installed.
    remote_build = f"{workspace}:{prefix}-build" in os.environ.get("WORKER_JOBS", "").split()
    worker = str(Path.home() / ".local/bin/enso-worker")
    checks = []
    for line in env("WORKFLOW_CHECKS").splitlines():
        line = line.strip()
        if not line:
            continue
        check, _, command = line.partition(":")
        if not command.strip():
            sys.exit(f"configure_workflow: WORKFLOW_CHECKS line {line!r} is not 'name: command'")
        if remote_build:
            run = q(f"{worker} check -- bash -c {shlex.quote(command.strip())}")
        else:
            run = q('cd "$ENSO_TASK_DIR" && ' + command.strip())
        timeout = int(env("WORKFLOW_CHECK_TIMEOUT", "1200"))
        checks.append(f"  - name: {check.strip()}\n    command: {run}\n    timeout: {timeout}")

    values = {
        "WORKFLOW_NAME": q(name),
        "ENABLED": "true" if enabled(project_md) else "false",
        "REPO_DIR": q(repo_dir),
        "WORKFLOW_BASE": q(base),
        "SETUP": q("true" if remote_build else f'cd "$ENSO_TASK_DIR" && {env("WORKFLOW_SETUP")}'),
        "WORKFLOW_MAX_CONCURRENCY": str(int(env("WORKFLOW_MAX_CONCURRENCY", "2"))),
        "BUILD_CHECKS": "\n".join(checks),
        "LORE_ASSIGNEE": assignee,
        "JOB_PREFIX": prefix,
    }
    changed = []
    text = Template((SOURCE / "PROJECT.md.tmpl").read_text()).substitute(values)
    # The body and output lines mention the base and name unquoted; those read as prose.
    text = text.replace(f"on {q(base)}", f"on {base}").replace(f"\n{q(name)} development", f"\n{name} development")
    if write(project_md, text):
        changed.append(project_md)

    settings = {
        "ENSO_BIN": env("ENSO_BIN"),
        "ENSO_PROJECT": key,
        "LORE_PROJECT": lore_project,
        "LORE_HOLDER": holder,
        "LORE_ASSIGNEE": assignee,
        "LORE_MAX_NEW": env("LORE_MAX_NEW", "1"),
        "LORE_STATUS_MAP": json.dumps({"pm": "in_progress", "publish": "review", "qa": "review", "signoff": "review", "merge": "review"}),
        "WORKFLOW_WIP_LIMIT": env("WORKFLOW_WIP_LIMIT", "3"),
        "WORKFLOW_REPO": env("WORKFLOW_REPO"),
        "WORKFLOW_BASE": base,
        "WORKFLOW_REPO_DIR": repo_dir,
        "WORKFLOW_CHANNEL": env("WORKFLOW_CHANNEL"),
        "WORKFLOW_APPROVERS": " ".join(approvers),
        "WORKFLOW_AGENT": env("AGENT_NAME"),
        "WORKFLOW_CI_WAIT": env("WORKFLOW_CI_WAIT", "2700"),
    }
    lines = ["# Rendered by enso-agent-bootstrap (lib/workflow.sh); re-running install rewrites it."]
    lines += [f"export {k}={shlex.quote(v)}" for k, v in settings.items()]
    if write(project_dir / "workflow.env", "\n".join(lines) + "\n"):
        changed.append(project_dir / "workflow.env")

    for script in SCRIPTS:
        target = project_dir / script
        mode = 0o700 if script.endswith(".sh") and script != "common.sh" else 0o600
        if write(target, (SOURCE / script).read_text(), mode):
            changed.append(target)

    prompt_values = {
        "REPO_DIR": repo_dir,
        "WORKFLOW_BASE": base,
        "APPROVER_LABEL": approver_label,
        "JOB_PREFIX": prefix,
    }
    for stage, (timeout, kind) in STAGES.items():
        path = jobs_dir / f"{prefix}-{stage}" / "JOB.md"
        if f"{workspace}:{prefix}-{stage}" in os.environ.get("WORKER_JOBS", "").split():
            # A remote turn costs this VM nothing while it runs; big features take hours.
            # Keep it under the sandbox session (WORKER_TIMEOUT, default 4h).
            timeout = int(env("WORKER_JOB_TIMEOUT", "10800"))
        if kind == "command":
            prompt = Template((SOURCE / "stages" / "command.md").read_text()).substitute(COMMAND=f"./{stage}-pr.sh")
            agent_text = ""
        else:
            prompt = Template((SOURCE / "stages" / f"{stage}.md").read_text()).substitute(prompt_values)
            agent_text = agent_block(review_agent if kind == "review" else agent)
        front = (
            f"---\nname: {q(f'{name}: {stage}')}\nproject: {key}\nstage: {stage}\nworkflow: 2\n"
            f"enabled: {'true' if enabled(path) else 'false'}\ntimeout: {timeout}\n{agent_text}---\n\n"
        )
        if write(path, front + prompt):
            changed.append(path)
        # enso runs one instance of a job at a time; a remote stage gets WORKER_PARALLEL
        # identical jobs (<job>-2, <job>-3, …) so that many tasks build at once. Copies
        # follow the main job's enabled state; copies past the count are disabled.
        if f"{workspace}:{prefix}-{stage}" in os.environ.get("WORKER_JOBS", "").split():
            parallel = max(1, int(env("WORKER_PARALLEL", "1")))
            for copy in sorted(jobs_dir.glob(f"{prefix}-{stage}-[0-9]*")):
                if copy.name.rsplit("-", 1)[-1].isdigit() and int(copy.name.rsplit("-", 1)[-1]) > parallel:
                    job_md = copy / "JOB.md"
                    if job_md.exists() and write(job_md, job_md.read_text().replace("enabled: true", "enabled: false", 1)):
                        changed.append(job_md)
            for n in range(2, parallel + 1):
                copy_md = jobs_dir / f"{prefix}-{stage}-{n}" / "JOB.md"
                copy_front = front.replace(f"name: {q(f'{name}: {stage}')}", f"name: {q(f'{name}: {stage} ({n})')}", 1)
                if write(copy_md, copy_front + prompt):
                    changed.append(copy_md)

    dispatch = jobs_dir / f"{prefix}-lore-dispatch" / "JOB.md"
    text = (
        f"---\nname: {q(f'{name}: Lore dispatch')}\nschedule: {q(env('WORKFLOW_DISPATCH_SCHEDULE', '*/5 * * * *'))}\n"
        f"enabled: {'true' if enabled(dispatch) else 'false'}\n"
        f"command: {q(f'bash {project_dir}/lore-bridge.sh dispatch')}\ntimeout: 240\n"
        f"concurrency:\n  group: {prefix}-lore\n  on_busy: skip\n---\n\n"
        f"Renew {holder}'s Lore claims, start Lore tickets assigned to {assignee} as {key} tasks\n"
        f"(at most {settings['WORKFLOW_WIP_LIMIT']} active at once), and repair claims a missed hook left behind.\n"
    )
    if write(dispatch, text):
        changed.append(dispatch)

    agents = ws_dir / "AGENTS.md"
    section = Template((ROOT / "templates" / "AGENTS.workflow.md").read_text()).substitute(
        LORE_ASSIGNEE=assignee,
        WORKFLOW_PROJECT=key,
        APPROVER_LABEL=approver_label,
        SIGNOFF_LABEL=signoff_label,
        LORE_HOLDER=holder,
        LORE_PROJECT=lore_project,
    )
    block = f"{MARK_START}\n{section.rstrip()}\n{MARK_END}\n"
    current = agents.read_text() if agents.exists() else ""
    pattern = re.compile(re.escape(MARK_START) + r".*?" + re.escape(MARK_END) + r"\n?", re.S)
    updated = pattern.sub(lambda _: block, current) if pattern.search(current) else current.rstrip() + "\n\n" + block
    if write(agents, updated, 0o644):
        changed.append(agents)

    for path in changed:
        print(f"    wrote {path}")
    print(f"    {key}: project {'enabled' if values['ENABLED'] == 'true' else 'disabled'}; "
          f"enabled jobs: {', '.join(p.parent.name for p in sorted(jobs_dir.glob(prefix + '-*/JOB.md')) if enabled(p)) or 'none'}")


if __name__ == "__main__":
    main()
