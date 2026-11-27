"""Print the latest accepted output of one stage from `enso task show REF --json` on stdin."""
import json
import sys

STAGE = sys.argv[1]
latest = ""


def text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("text", "output", "summary", "message"):
            if isinstance(value.get(key), str):
                return value[key]
    return ""


def walk(node):
    global latest
    if isinstance(node, dict):
        if (
            node.get("stage") == STAGE
            and node.get("status", "accepted") == "accepted"
            and text(node.get("output")).strip()
        ):
            latest = text(node["output"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(json.load(sys.stdin))
print(latest.strip())
