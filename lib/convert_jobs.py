#!/usr/bin/env python3
"""Convert a legacy enso home's home-level jobs to enso 0.4 workspace jobs.

The enso 2.x fork kept jobs in `<home>/jobs/<name>/JOB.md` with flat
frontmatter (`provider`, `model`, `workspace`, `prerun`, `postrun`, …).
enso 0.4 keeps them in `workspaces/<ws>/jobs/<name>/JOB.md`, with the agent
triple under `agent` and hooks as `gate`/`postrun` commands. Each job lands in
the workspace its frontmatter named (else DEFAULT_WS), with its sibling
scripts; an existing destination is never overwritten. Unknown keys are
reported and dropped; `enso doctor` validates the result.

Usage: convert_jobs.py <legacy-home> <new-home> <default-workspace>
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys

CARRIED = {"name", "schedule", "enabled", "catch_up", "provider", "model", "effort",
           "workspace", "prerun", "postrun", "timeout"}


def parse(text: str) -> tuple[dict[str, str], str]:
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return {}, text
    front: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#") or line.startswith((" ", "\t")):
            continue
        key, _, value = line.partition(":")
        front[key.strip()] = value.strip().strip("\"'")
    return front, m.group(2)


def q(value: str) -> str:
    return json.dumps(value)  # a JSON string is a valid double-quoted YAML scalar


def main() -> None:
    old, new, default_ws = sys.argv[1:4]
    root = os.path.join(old, "jobs")
    if not os.path.isdir(root):
        return
    for name in sorted(os.listdir(root)):
        src = os.path.join(root, name)
        job = os.path.join(src, "JOB.md")
        if not os.path.isfile(job):
            continue
        with open(job, encoding="utf-8") as fh:
            front, body = parse(fh.read())
        ws = front.get("workspace") or default_ws
        if not os.path.isdir(os.path.join(new, "workspaces", ws)):
            print(f"    ! job {name}: workspace {ws!r} does not exist in the new home; using {default_ws}")
            ws = default_ws
        dest = os.path.join(new, "workspaces", ws, "jobs", name)
        if os.path.exists(dest):
            print(f"    job {name}: {ws}:{name} already exists; left alone")
            continue
        enabled = front.get("enabled", "true").lower() not in ("false", "no", "0")
        lines = ["---", f"name: {q(front.get('name') or name)}"]
        if front.get("schedule"):
            lines.append(f"schedule: {q(front['schedule'])}")
        lines.append(f"enabled: {'true' if enabled else 'false'}")
        if front.get("catch_up"):
            lines.append(f"catch_up: {'true' if front['catch_up'].lower() == 'true' else 'false'}")
        lines += ["agent:", f"  provider: {q(front.get('provider') or 'claude')}",
                  f"  model: {q(front.get('model') or 'opus')}", f"  effort: {q(front.get('effort') or 'high')}"]
        timeout = front.get("timeout", "")
        if timeout.isdigit():
            lines.append(f"timeout: {timeout}")
        for hook, key in (("prerun", "gate"), ("postrun", "postrun")):
            if front.get(hook):
                lines += [f"{key}:", f"  command: {q('bash ' + front[hook])}", "  timeout: 600"]
        lines.append("---")
        dropped = sorted(set(front) - CARRIED)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copytree(src, dest, symlinks=True)
        with open(os.path.join(dest, "JOB.md"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n" + body.replace("{{prerun_output}}", "{{gate_output}}"))
        print(f"    job {name} → {ws}:{name} ({'enabled' if enabled else 'disabled'})"
              + (f"; dropped keys: {', '.join(dropped)}" if dropped else ""))


if __name__ == "__main__":
    main()
