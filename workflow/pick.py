#!/usr/bin/env python3
"""Choose the agent's next Lore ticket from the project's goals (dispatch, before the bridge).

    pick.py            WORKFLOW_PICK=off|shadow|on (default off)

Lore owns the order: the roadmap's current goals (`lore recall roadmap`) name the tickets
that support them, and `lore work list` is the ranked backlog. A candidate is an open,
unclaimed `todo` ticket assigned to no one, that supports a current goal and has no
`no-agent` label. Candidates are ordered by goal priority, then short-term goals first,
then Lore's rank.

With TYPESAFE_API_KEY, Jev screens the first few candidates (one request each, three
yes/no judgments): is it work an agent can do (code, not contracts or accounts), can a
brief be written without a client decision, and does it introduce UI the client has not
seen (which the design route will use). Without a key, the screen is skipped.

    shadow  tell the operator once a day (or when the choice changes) what it would pick
    on      assign the pick to LORE_ASSIGNEE in Lore; the bridge then admits it as usual

Only one ticket per run, and only when the agent has room (LORE_MAX_NEW > 0) and nothing
already assigned to it is waiting.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODE = os.environ.get("WORKFLOW_PICK", "off")
PROJECT = os.environ.get("LORE_PROJECT", "")
ASSIGNEE = os.environ.get("LORE_ASSIGNEE", "")
CURRENT = {"planned", "in_progress", "active", "open"}
PRIORITY = {"P1": 0, "P2": 1, "P3": 2}
SCREEN = int(os.environ.get("WORKFLOW_PICK_SCREEN", "6"))


def lore(*args: str):
    out = subprocess.run(["lore", *args, "-p", PROJECT], capture_output=True, text=True, timeout=180)
    if out.returncode != 0:
        raise RuntimeError(f"lore {' '.join(args[:2])}: {(out.stderr or out.stdout).strip()[:300]}")
    return json.loads(out.stdout)


def goals() -> list[dict]:
    data = lore("recall", "roadmap", "--json")
    found = (data.get("roadmap") or {}).get("goals") if isinstance(data, dict) else None
    if found is None and isinstance(data, dict):
        found = data.get("goals")
    return [g for g in found or [] if str(g.get("status", "planned")) in CURRENT and g.get("kind", "goal") == "goal"]


def candidates() -> tuple[list[dict], bool]:
    tickets = lore("work", "list", "--json")
    mine_waiting = any(
        t.get("status") == "todo" and not t.get("claim") and str(t.get("assignee") or "").lower() == ASSIGNEE.lower()
        for t in tickets
    )
    support: dict[str, dict] = {}
    for g in goals():
        for key in g.get("work_items") or []:
            best = support.get(key)
            rank = (PRIORITY.get(g.get("priority"), 3), 0 if g.get("horizon") == "short_term" else 1)
            if best is None or rank < best["_rank"]:
                support[key] = {**g, "_rank": rank}
    out = []
    for i, t in enumerate(tickets):
        labels = [str(x).lower() for x in t.get("labels") or []]
        if (t.get("status") == "todo" and not t.get("claim") and not t.get("assignee")
                and t.get("key") in support and "no-agent" not in labels):
            g = support[t["key"]]
            out.append({**t, "goal": g, "_order": (*g["_rank"], i)})
    return sorted(out, key=lambda t: t["_order"]), mine_waiting


QUESTIONS = {
    "agent_work": {
        "type": "noul",
        "instructions": "Is `ticket` software work a coding agent could carry out in the project's code (build, fix, change or test something), rather than work only people can do (contracts, legal, accounts, meetings, research with clients, content the client must write)?",
        "criteria": {"true": "Code or configuration work an agent can do", "false": "Needs people, not code"},
    },
    "ready": {
        "type": "noul",
        "instructions": "Could a brief for `ticket` be written from what it says, or would the agent first need a decision from the client that the ticket leaves open (scope, which option, approval of an approach)?",
        "criteria": {"true": "Clear enough to start; small details can be asked later", "false": "Blocked on an open client decision"},
    },
    "new_ui": {
        "type": "noul",
        "instructions": "Does `ticket` introduce user interface the client has not seen yet: a new screen, page, component, flow or layout, rather than changing copy, styling, behaviour or bugs in existing screens?",
        "criteria": {"true": "New UI that needs design approval", "false": "No new UI, or changes to existing UI only"},
    },
}


def screen(t: dict) -> dict | None:
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        return None
    state = {
        "ticket": {"key": t["key"], "title": t.get("title", ""), "labels": t.get("labels") or [],
                   "description": str(t.get("description") or "")[:3000]},
        "goal": {"outcome": t["goal"].get("item", ""), "why": t["goal"].get("why", "")},
    }
    body = json.dumps({"model": os.environ.get("JEV_MODEL", "jev-latest"), "state": state, "questions": QUESTIONS}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        answers = json.load(resp).get("answers", {})
    return {k: float((answers.get(k) or {}).get("noul", 0.0)) for k in QUESTIONS}


def operator(text: str) -> None:
    enso = os.environ.get("ENSO_BIN", "enso")
    subprocess.run([enso, "message", "send", "-", "--workspace", os.environ.get("ENSO_WORKSPACE", "")],
                   input=text, text=True, capture_output=True)


def main() -> int:
    if MODE not in ("shadow", "on") or not PROJECT or not ASSIGNEE:
        return 0
    if int(os.environ.get("LORE_MAX_NEW", "0") or 0) <= 0:
        return 0
    cands, mine_waiting = candidates()
    if mine_waiting or not cands:
        return 0
    pick, verdict, skipped = None, None, []
    for t in cands[:SCREEN]:
        v = screen(t)
        if v is None or (v["agent_work"] >= 0.6 and v["ready"] >= 0.5):
            pick, verdict = t, v
            break
        skipped.append(f"{t['key']} ({'not agent work' if v['agent_work'] < 0.6 else 'needs a client decision'})")
    if pick is None:
        return 0
    goal = pick["goal"]
    why = f"supports “{str(goal.get('item', ''))[:90]}” ({goal.get('priority', '?')}, {str(goal.get('horizon', '')).replace('_', ' ')})"
    ui = "" if verdict is None else ("; new UI, so designs first" if verdict["new_ui"] >= 0.5 else "")
    line = f"*{pick['key']}* {pick.get('title', '')[:80]}: {why}{ui}"
    if os.environ.get("PICK_DRY"):
        print(f"would pick: {line}" + (f" | screened {verdict}" if verdict else "") + (f" | skipped {skipped}" if skipped else ""))
        return 0
    if MODE == "shadow":
        mark = HERE / "state" / "pick.shadow"
        stamp = f"{dt.date.today()} {pick['key']}"
        if (mark.read_text().strip() if mark.exists() else "") != stamp:
            extra = f" Skipped: {', '.join(skipped)}." if skipped else ""
            operator(f"Would pick next (shadow mode): {line}.{extra}")
            mark.parent.mkdir(exist_ok=True)
            mark.write_text(stamp)
        print(f"pick (shadow): {pick['key']}")
        return 0
    subprocess.run(["lore", "work", "set", pick["key"], "-p", PROJECT, "--assignee", ASSIGNEE,
                    "--reason", f"Picked by the agent: {why}{ui}", "--by", os.environ.get("LORE_HOLDER", "enso")],
                   check=True, capture_output=True, text=True, timeout=120)
    print(f"picked {pick['key']}: {why}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # never break dispatch; the error line reaches the job log
        print(f"pick.py: {exc}", file=sys.stderr)
        sys.exit(0)
