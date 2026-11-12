#!/usr/bin/env python3
"""Word counts of an enso agent's chat replies, per workspace. Prints numbers only.

Run on the agent VM:  python3 reply-lengths.py [--since 2026-11-12T18:00]
or from a laptop:     ssh <vm>.exe.xyz python3 - --since … < contrib/reply-lengths.py

A reply is the last assistant text before the next human message in a Claude
session under ~/.claude/projects/*enso-workspaces-*/ (what enso posts to Slack).
"""
import glob, json, os, statistics as st, sys

since = sys.argv[sys.argv.index("--since") + 1] if "--since" in sys.argv else ""
rows = []
for d in glob.glob(os.path.expanduser("~/.claude/projects/*enso-workspaces-*")):
    ws = d.split("enso-workspaces-")[-1]
    for f in glob.glob(d + "/*.jsonl"):
        last = None
        for line in open(f, errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") or {}
            c = m.get("content")
            if e.get("type") == "user":
                if not (isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c)):
                    if last: rows.append((ws, *last))
                    last = None
            elif e.get("type") == "assistant" and isinstance(c, list):
                txt = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text").strip()
                if txt: last = (e.get("timestamp", ""), len(txt.split()))
        if last: rows.append((ws, *last))

rows = [r for r in rows if r[1] >= since]
for ws in sorted({r[0] for r in rows}):
    w = [n for _, ts, n in sorted(r for r in rows if r[0] == ws)][-30:]
    print(f"{ws}: last {len(w)} replies{' since ' + since if since else ''}: median {st.median(w):.0f} words, "
          f"mean {st.mean(w):.0f}, max {max(w)}, over 100 words: {sum(n > 100 for n in w)}")
if not rows:
    print("no replies found")
